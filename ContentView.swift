import SwiftUI
import MapKit
import CoreLocation
import CoreBluetooth

// MARK: - Navigation & BLE Manager
final class ScooterNavManager: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var bleStatus = "Scanning for Scooter Nav Pro..."
    @Published var isConnected = false
    @Published var searchResults: [MKMapItem] = []
    @Published var activeRoute: MKRoute?
    @Published var currentInstruction = "Ready"
    @Published var nextStepDistance = "--"
    @Published var remainingDistance = "--"

    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let rxCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    private var centralManager: CBCentralManager!
    private var espPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var steps: [MKRoute.Step] = []
    private var currentStepIndex = 0
    private var lastSentTime = Date.distantPast

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 2
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()

        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Search & Route Calculation
    func searchDestination(query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let loc = lastLocation {
            request.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 25000, longitudinalMeters: 25000)
        }
        MKLocalSearch(request: request).start { [weak self] response, _ in
            DispatchQueue.main.async {
                self?.searchResults = response?.mapItems ?? []
            }
        }
    }

    func startNavigation(to destination: MKMapItem) {
        guard let userCoord = lastLocation?.coordinate else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: userCoord))
        request.destination = destination
        request.transportType = .automobile

        MKDirections(request: request).calculate { [weak self] response, _ in
            guard let self = self, let route = response?.routes.first else { return }
            DispatchQueue.main.async {
                self.activeRoute = route
                self.steps = route.steps.filter { !$0.instructions.isEmpty }
                self.currentStepIndex = 0
                self.searchResults = []
            }
            self.sendRoutePolyline(route.polyline)
        }
    }

    func stopNavigation() {
        activeRoute = nil
        steps = []
        currentStepIndex = 0
        currentInstruction = "Ready"
        nextStepDistance = "--"
        remainingDistance = "--"
        writeBLE("R:CLEAR")
    }

    // MARK: - Simplify & Send Route Polyline over BLE
    private func sendRoutePolyline(_ polyline: MKPolyline) {
        let count = polyline.pointCount
        guard count > 1 else { return }
        let pts = polyline.points()
        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(count)
        for i in 0..<count {
            coords.append(pts[i].coordinate)
        }

        // Simplify down to <= 200 points so it fits ESP32's MAX_POINTS (250)
        var tolerance = 0.00005 // ~5 meters
        var simplified = rdpSimplify(coords, epsilon: tolerance)
        while simplified.count > 200 {
            tolerance *= 1.5
            simplified = rdpSimplify(coords, epsilon: tolerance)
        }

        Task {
            self.writeBLE("R:CLEAR")
            try? await Task.sleep(nanoseconds: 40_000_000)

            var chunk = "R:"
            for coord in simplified {
                let pair = String(format: "%.5f,%.5f;", coord.latitude, coord.longitude)
                if chunk.utf8.count + pair.utf8.count > 140 {
                    self.writeBLE(chunk)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    chunk = "R:" + pair
                } else {
                    chunk += pair
                }
            }
            if chunk.count > 2 {
                self.writeBLE(chunk)
            }
        }
    }

    // Ramer-Douglas-Peucker polyline simplification
    private func rdpSimplify(_ points: [CLLocationCoordinate2D], epsilon: Double) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }
        var maxDist = 0.0
        var index = 0
        let first = points.first!
        let last = points.last!

        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(points[i], lineStart: first, lineEnd: last)
            if d > maxDist {
                maxDist = d
                index = i
            }
        }
        if maxDist > epsilon {
            let left = rdpSimplify(Array(points[0...index]), epsilon: epsilon)
            let right = rdpSimplify(Array(points[index..<points.count]), epsilon: epsilon)
            return left.dropLast() + right
        } else {
            return [first, last]
        }
    }

    private func perpendicularDistance(_ p: CLLocationCoordinate2D, lineStart a: CLLocationCoordinate2D, lineEnd b: CLLocationCoordinate2D) -> Double {
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        if dx == 0 && dy == 0 {
            return hypot(p.longitude - a.longitude, p.latitude - a.latitude)
        }
        let num = abs(dy * p.longitude - dx * p.latitude + b.longitude * a.latitude - b.latitude * a.longitude)
        return num / hypot(dx, dy)
    }

    // MARK: - Live GPS & Turn-by-Turn Updates
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc

        guard let route = activeRoute, !steps.isEmpty else { return }
        guard Date().timeIntervalSince(lastSentTime) >= 0.8 else { return }
        lastSentTime = Date()

        // Advance step when within 25m of current maneuver start point
        if currentStepIndex < steps.count - 1 {
            let stepCoord = steps[currentStepIndex].polyline.coordinate
            let stepLoc = CLLocation(latitude: stepCoord.latitude, longitude: stepCoord.longitude)
            if loc.distance(from: stepLoc) < 25 {
                currentStepIndex += 1
            }
        }

        let activeStep = steps[currentStepIndex]
        let maneuverCoord = activeStep.polyline.coordinate
        let distToTurn = loc.distance(from: CLLocation(latitude: maneuverCoord.latitude, longitude: maneuverCoord.longitude))

        // Estimate remaining trip distance
        var remMeters = distToTurn
        if currentStepIndex + 1 < steps.count {
            for i in (currentStepIndex + 1)..<steps.count {
                remMeters += steps[i].distance
            }
        }
        remMeters = min(remMeters, route.distance)

        let dirCode = mapDirectionCode(activeStep.instructions)
        let stepDistStr = formatDistance(distToTurn)
        let remDistStr = formatDistance(remMeters)
        let cleanStreet = activeStep.instructions
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let heading = loc.course >= 0 ? loc.course : bearing(from: loc.coordinate, to: maneuverCoord)

        DispatchQueue.main.async {
            self.currentInstruction = cleanStreet
            self.nextStepDistance = stepDistStr
            self.remainingDistance = remDistStr
        }

        // Format expected by ESP32: "N:lat,lon,heading,DIR,stepDist,street,totalRem"
        let packet = String(
            format: "N:%.5f,%.5f,%.1f,%@,%@,%@,%@",
            loc.coordinate.latitude,
            loc.coordinate.longitude,
            heading,
            dirCode,
            stepDistStr,
            cleanStreet.isEmpty ? "Continue" : cleanStreet,
            remDistStr
        )
        writeBLE(packet)
    }

    private func mapDirectionCode(_ instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("u-turn") { return "UTURN" }
        if lower.contains("left")   { return "LEFT" }
        if lower.contains("right")  { return "RIGHT" }
        return "STRAIGHT"
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            let rounded = max(10, Int((meters / 10).rounded()) * 10)
            return "\(rounded) m"
        } else {
            return String(format: "%.1f km", meters / 1000.0)
        }
    }

    private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - CoreBluetooth Delegates
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        } else {
            bleStatus = "Turn on iPhone Bluetooth"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name == "Scooter Nav Pro" || advertisementData[CBAdvertisementDataLocalNameKey] as? String == "Scooter Nav Pro" {
            espPeripheral = peripheral
            espPeripheral?.delegate = self
            centralManager.stopScan()
            bleStatus = "Connecting to Scooter Nav Pro..."
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        bleStatus = "Connected to Scooter Nav Pro"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        rxCharacteristic = nil
        bleStatus = "Reconnecting..."
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([rxCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars where char.uuid == rxCharUUID {
            rxCharacteristic = char
        }
    }

    private func writeBLE(_ text: String) {
        guard let peripheral = espPeripheral,
              let char = rxCharacteristic,
              let data = text.data(using: .utf8) else { return }
        peripheral.writeValue(data, for: char, type: .withoutResponse)
    }
}

// MARK: - SwiftUI Screen
struct ContentView: View {
    @StateObject private var nav = ScooterNavManager()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                // Connection Status Banner
                HStack {
                    Circle()
                        .fill(nav.isConnected ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(nav.bleStatus)
                        .font(.subheadline.bold())
                    Spacer()
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                // Destination Search Bar
                HStack {
                    TextField("Enter destination (e.g. MG Road)", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { nav.searchDestination(query: query) }
                    Button("Go") {
                        nav.searchDestination(query: query)
                    }
                    .buttonStyle(.borderedProminent)
                }

                // Search Results List
                if !nav.searchResults.isEmpty {
                    List(nav.searchResults, id: \.self) { item in
                        Button {
                            nav.startNavigation(to: item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Destination").font(.headline)
                                Text(item.placemark.title ?? "").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                // Active Navigation Summary Card
                if nav.activeRoute != nil {
                    VStack(spacing: 8) {
                        Text(nav.nextStepDistance)
                            .font(.system(size: 38, weight: .bold))
                            .foregroundColor(.green)
                        Text(nav.currentInstruction)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("Remaining: \(nav.remainingDistance)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button("End Route", role: .destructive) {
                            nav.stopNavigation()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Scooter Nav")
        }
    }
}
// END OF FILE
