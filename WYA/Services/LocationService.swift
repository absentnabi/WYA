import CoreLocation
import WYACore

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let unionSquare = Coordinate(latitude: 40.735736, longitude: -73.990568)

    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var location: CLLocation?

    var onAuthorization: (@MainActor (CLAuthorizationStatus) -> Void)?
    var onLocation: (@MainActor (CLLocation) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 30
        authorization = manager.authorizationStatus
    }

    func request() {
        authorization = manager.authorizationStatus
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.onAuthorization?(status)
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.location = location
            self.onLocation?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.onFailure?(message)
        }
    }
}
