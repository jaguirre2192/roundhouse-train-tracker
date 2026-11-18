import CoreLocation
import SwiftUI

@MainActor
final class MapLocationPermissionController: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?

    private static let maximumHorizontalAccuracy: CLLocationAccuracy = 1_000
    private static let maximumLocationAge: TimeInterval = 120

    private let manager = CLLocationManager()
    private var authorizationStatus: CLAuthorizationStatus?
    private var isMapSelected = false
    private var hasRequestedWhenInUse = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
    }

    func requestWhenInUseIfNeeded(isMapSelected: Bool = true) {
        self.isMapSelected = isMapSelected
        guard isMapSelected else {
            manager.stopUpdatingLocation()
            return
        }
        updateLocationAccess()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            location = nil
        }
        updateLocationAccess()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last,
              latest.horizontalAccuracy >= 0,
              latest.horizontalAccuracy <= Self.maximumHorizontalAccuracy,
              latest.timestamp <= .now.addingTimeInterval(5),
              Date.now.timeIntervalSince(latest.timestamp) <= Self.maximumLocationAge else {
            location = nil
            return
        }
        location = latest
    }

    private func updateLocationAccess() {
        guard isMapSelected else { return }
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .notDetermined:
            guard !hasRequestedWhenInUse else { return }
            hasRequestedWhenInUse = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted, .none:
            manager.stopUpdatingLocation()
        @unknown default:
            manager.stopUpdatingLocation()
        }
    }
}
