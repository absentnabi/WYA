import Foundation
import WYACore

@MainActor
final class ArrivalCache {
    struct Snapshot: Codable {
        var savedAt: Date
        var latitude: Double
        var longitude: Double
        var arrivals: [StoredArrival]
    }

    struct StoredArrival: Codable {
        var routeID: String
        var stopID: String
        var epoch: TimeInterval
        var destination: String?
    }

    private(set) var snapshot: Snapshot?
    private let url: URL

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("wya-nearby-cache.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(coordinate: Coordinate, arrivals: [Arrival]) {
        let live = arrivals.filter { !$0.isSample && $0.epoch > Date().timeIntervalSince1970 - 30 }
        let snapshot = Snapshot(
            savedAt: Date(),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            arrivals: live.map {
                StoredArrival(routeID: $0.routeID, stopID: $0.stopID, epoch: $0.epoch, destination: $0.destination)
            }
        )
        self.snapshot = snapshot
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func restore(for access: [AccessPoint], now: Date = Date()) -> [String: [Arrival]]? {
        guard let snapshot else { return nil }
        if now.timeIntervalSince(snapshot.savedAt) > 6 * 3600 { return nil }
        let live = snapshot.arrivals.filter { $0.epoch > now.timeIntervalSince1970 - 30 }
        guard !live.isEmpty else { return nil }
        let arrivals = live.map {
            Arrival(routeID: $0.routeID, stopID: $0.stopID, epoch: $0.epoch, destination: $0.destination, isSample: false)
        }
        var grouped: [String: [Arrival]] = [:]
        for point in access {
            let ids = Set(point.platformIDs + point.memberIDs + [point.id])
            let matched = arrivals.filter { ids.contains($0.stopID) }.sorted { $0.epoch < $1.epoch }
            if !matched.isEmpty {
                grouped[point.id] = matched
            }
        }
        return grouped.isEmpty ? nil : grouped
    }
}
