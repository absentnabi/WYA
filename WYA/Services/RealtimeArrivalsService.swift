import Foundation
import WYACore

struct ArrivalFetch: Sendable {
    var byAccessID: [String: [Arrival]]
    var subwaySample: Bool
    var busSample: Bool
    var errors: [String]
    var fetchedAt: Date
    var usedNetwork: Bool
}

final class RealtimeArrivalsService: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func fetch(access: [AccessPoint], secrets: AppSecrets) async -> ArrivalFetch {
        let now = Date()
        let subwayStops = access.filter { $0.mode == .subway }
        let busStops = Array(access.filter { $0.mode != .subway }.prefix(6))
        var arrivals: [Arrival] = []
        var errors: [String] = []
        var usedNetwork = false

        if secrets.hasSubway {
            let result = await subwayArrivals(stops: subwayStops, key: secrets.subwayKey, now: now)
            arrivals.append(contentsOf: result.arrivals)
            errors.append(contentsOf: result.errors)
            usedNetwork = usedNetwork || result.usedNetwork
        } else {
            for stop in subwayStops {
                arrivals.append(contentsOf: FixtureArrivals.make(stopID: stop.id, routeIDs: stop.routeIDs, now: now))
            }
        }

        if secrets.hasBus {
            let result = await busArrivals(stops: busStops, key: secrets.busKey, now: now)
            arrivals.append(contentsOf: result.arrivals)
            errors.append(contentsOf: result.errors)
            usedNetwork = usedNetwork || result.usedNetwork
        } else {
            for stop in busStops {
                arrivals.append(contentsOf: FixtureArrivals.make(stopID: stop.id, routeIDs: stop.routeIDs, now: now))
            }
        }

        return ArrivalFetch(
            byAccessID: group(arrivals, onto: access),
            subwaySample: !secrets.hasSubway && !subwayStops.isEmpty,
            busSample: !secrets.hasBus && !busStops.isEmpty,
            errors: errors,
            fetchedAt: now,
            usedNetwork: usedNetwork
        )
    }

    private func subwayArrivals(stops: [AccessPoint], key: String, now: Date) async -> (arrivals: [Arrival], errors: [String], usedNetwork: Bool) {
        let routes = Set(stops.flatMap(\.routeIDs))
        var feeds = Set<SubwayRealtimeFeed>()
        for route in routes {
            feeds.formUnion(SubwayRealtimeFeed.feeds(containing: route))
        }
        let interesting = Set(stops.flatMap { $0.platformIDs + $0.memberIDs })
        if feeds.isEmpty || interesting.isEmpty {
            return ([], [], false)
        }

        return await withTaskGroup(of: FeedBatch.self) { group in
            for feed in feeds {
                group.addTask {
                    var request = URLRequest(url: feed.url)
                    request.setValue(key, forHTTPHeaderField: "x-api-key")
                    do {
                        let (data, response) = try await self.session.data(for: request)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                            return FeedBatch(error: "Subway feed \(feed.rawValue) returned \(code).")
                        }
                        let parsed = try GTFSRTParser.parse(data, interestingStopIDs: interesting, now: now)
                        return FeedBatch(arrivals: parsed)
                    } catch {
                        return FeedBatch(error: "Subway feed \(feed.rawValue) didn't load.")
                    }
                }
            }
            var arrivals: [Arrival] = []
            var errors: [String] = []
            for await batch in group {
                arrivals.append(contentsOf: batch.arrivals)
                if let error = batch.error { errors.append(error) }
            }
            return (arrivals, errors, true)
        }
    }

    private func busArrivals(stops: [AccessPoint], key: String, now: Date) async -> (arrivals: [Arrival], errors: [String], usedNetwork: Bool) {
        if stops.isEmpty { return ([], [], false) }
        return await withTaskGroup(of: FeedBatch.self) { group in
            for stop in stops {
                let stopID = stop.platformIDs.first ?? stop.memberIDs.first ?? stop.id
                group.addTask {
                    do {
                        let arrivals = try await self.monitor(stopID: stopID, key: key, now: now)
                        return FeedBatch(arrivals: arrivals)
                    } catch {
                        return FeedBatch(error: "Bus stop \(stop.name) didn't respond.")
                    }
                }
            }
            var arrivals: [Arrival] = []
            var errors: [String] = []
            for await batch in group {
                arrivals.append(contentsOf: batch.arrivals)
                if let error = batch.error { errors.append(error) }
            }
            if errors.count == stops.count {
                return ([], ["Bus Time didn't return arrivals."], true)
            }
            return (arrivals, [], true)
        }
    }

    private func monitor(stopID: String, key: String, now: Date) async throws -> [Arrival] {
        let hosts = [
            "https://bustime.mta.info/api/siri/stop-monitoring.json",
            "https://bustime-classic.mta.info/api/siri/stop-monitoring.json"
        ]
        var lastError: Error = URLError(.badServerResponse)
        for host in hosts {
            guard var components = URLComponents(string: host) else { continue }
            components.queryItems = [
                URLQueryItem(name: "key", value: key),
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "OperatorRef", value: "MTA"),
                URLQueryItem(name: "MonitoringRef", value: stopID),
                URLQueryItem(name: "StopMonitoringDetailLevel", value: "minimum"),
                URLQueryItem(name: "MaximumStopVisits", value: "4")
            ]
            guard let url = components.url else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                return try SIRIParser.parse(json: data, monitoredStopID: stopID, now: now)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private struct FeedBatch: Sendable {
        var arrivals: [Arrival] = []
        var error: String?
    }

    private func group(_ arrivals: [Arrival], onto access: [AccessPoint]) -> [String: [Arrival]] {
        var grouped: [String: [Arrival]] = [:]
        for point in access {
            let ids = Set(point.platformIDs + point.memberIDs + [point.id])
            grouped[point.id] = arrivals
                .filter { ids.contains($0.stopID) }
                .sorted { $0.epoch < $1.epoch }
        }
        return grouped
    }
}
