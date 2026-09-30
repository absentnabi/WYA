import CoreLocation
import MapKit
import WYACore

struct ResolvedPlace: Sendable {
    var name: String
    var coordinate: Coordinate
}

enum GeocodeError: LocalizedError {
    case notFound
    case outside

    var errorDescription: String? {
        switch self {
        case .notFound: return "Couldn't find that place."
        case .outside: return "That place looks outside the NYC area WYA covers."
        }
    }
}

struct PlaceGeocoder: Sendable {
    func resolve(_ query: String) async throws -> ResolvedPlace {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.73, longitude: -73.94),
            span: MKCoordinateSpan(latitudeDelta: 0.9, longitudeDelta: 1.0)
        )
        let response = try await MKLocalSearch(request: request).start()
        let matches = response.mapItems.filter { item in
            let coordinate = item.placemark.coordinate
            return coordinate.latitude > 40.45 && coordinate.latitude < 41.05
                && coordinate.longitude > -74.35 && coordinate.longitude < -73.65
        }
        guard let item = matches.first else {
            throw response.mapItems.isEmpty ? GeocodeError.notFound : GeocodeError.outside
        }
        let coordinate = item.placemark.coordinate
        return ResolvedPlace(
            name: item.name ?? query,
            coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
    }
}
