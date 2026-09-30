import CoreLocation
import MapKit
import WYACore

struct WalkingRefiner: Sendable {
    func refine(_ plans: [TripPlan]) async -> [TripPlan] {
        var plans = plans
        for index in plans.indices.prefix(2) {
            plans[index] = await refine(plans[index])
        }
        return plans
    }

    private func refine(_ plan: TripPlan) async -> TripPlan {
        var plan = plan
        let walks: [(Int, Coordinate, Coordinate)] = plan.legs.enumerated().compactMap { index, leg in
            guard leg.kind == .walk, let from = leg.from, let to = leg.to else { return nil }
            return (index, from, to)
        }
        guard !walks.isEmpty else { return plan }
        await withTaskGroup(of: (Int, Int)?.self) { group in
            for walk in walks {
                group.addTask {
                    guard let seconds = try? await self.route(from: walk.1, to: walk.2) else { return nil }
                    return (walk.0, seconds)
                }
            }
            for await update in group {
                guard let update else { continue }
                plan.legs[update.0].seconds = max(30, update.1)
                plan.legs[update.0].detail = "Street walking route"
            }
        }
        return plan
    }

    private func route(from: Coordinate, to: Coordinate) async throws -> Int {
        let request = MKDirections.Request()
        request.source = mapItem(from)
        request.destination = mapItem(to)
        request.transportType = .walking
        let response = try await MKDirections(request: request).calculate()
        guard let time = response.routes.first?.expectedTravelTime else {
            throw URLError(.cannotParseResponse)
        }
        return Int(time.rounded())
    }

    private func mapItem(_ coordinate: Coordinate) -> MKMapItem {
        MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )))
    }
}
