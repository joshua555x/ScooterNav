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