import Foundation

public struct PatternHit: Hashable, Sendable {
    public let pattern: Int
    public let stopIndex: Int
}

public struct AccessPoint: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let coordinate: Coordinate
    public let distanceMeters: Double
    public let mode: TransitMode
    public let routeIDs: [String]
    public let memberIDs: [String]
    public let platformIDs: [String]

}

public struct TransitCatalog: Sendable {
    public let index: TransitIndex
    public let stopsByID: [String: TransitStop]
    public let routesByID: [String: TransitRoute]
    public let childIDsByParent: [String: [String]]
    private let hitsByStopID: [String: [PatternHit]]
    private let hitsByCell: [Cell: [PatternHit]]

    public init(index: TransitIndex) {
        self.index = index
        var stops: [String: TransitStop] = [:]
        stops.reserveCapacity(index.stops.count)
        var children: [String: [String]] = [:]
        for stop in index.stops {
            stops[stop.id] = stop
            if let parent = stop.parent {
                children[parent, default: []].append(stop.id)
            }
        }
        var routes: [String: TransitRoute] = [:]
        for route in index.routes {
            routes[route.id] = route
        }
        var byStop: [String: [PatternHit]] = [:]
        var byCell: [Cell: [PatternHit]] = [:]
        for (patternIndex, pattern) in index.patterns.enumerated() {
            for (stopIndex, patternStop) in pattern.stops.enumerated() {
                guard let stop = stops[patternStop.id] else { continue }
                let hit = PatternHit(pattern: patternIndex, stopIndex: stopIndex)
                byStop[stop.id, default: []].append(hit)
                if let parent = stop.parent {
                    byStop[parent, default: []].append(hit)
                }
                let cell = Cell(stop.coordinate)
                byCell[cell, default: []].append(hit)
            }
        }
        stopsByID = stops
        routesByID = routes
        childIDsByParent = children
        hitsByStopID = byStop
        hitsByCell = byCell
    }

    public func parentID(for stopID: String) -> String? {
        stopsByID[stopID]?.parent
    }

    public func hits(forStop stopID: String) -> [PatternHit] {
        hitsByStopID[stopID] ?? []
    }

    public func hits(near coordinate: Coordinate, radius: Double) -> [PatternHit] {
        let center = Cell(coordinate)
        var seen = Set<PatternHit>()
        var matches: [PatternHit] = []
        for dx in -1...1 {
            for dy in -1...1 {
                let cell = Cell(x: center.x + dx, y: center.y + dy)
                for hit in hitsByCell[cell] ?? [] {
                    guard seen.insert(hit).inserted else { continue }
                    guard let stop = stop(for: hit) else { continue }
                    if WalkingModel.nyc.distanceMeters(coordinate, stop.coordinate) <= radius {
                        matches.append(hit)
                    }
                }
            }
        }
        return matches
    }

    public func stop(for hit: PatternHit) -> TransitStop? {
        guard index.patterns.indices.contains(hit.pattern) else { return nil }
        let pattern = index.patterns[hit.pattern]
        guard pattern.stops.indices.contains(hit.stopIndex) else { return nil }
        return stopsByID[pattern.stops[hit.stopIndex].id]
    }

    public func nearby(
        to coordinate: Coordinate,
        subwayRadius: Double = 1000,
        busRadius: Double = 480,
        limit: Int = 18
    ) -> [AccessPoint] {
        let walking = WalkingModel.nyc
        let subwayWindow = subwayRadius / 111_000
        var subway: [(TransitStop, Double)] = []
        for stop in index.stops where stop.display && stop.mode == .subway {
            if abs(stop.lat - coordinate.latitude) > subwayWindow { continue }
            let distance = walking.distanceMeters(coordinate, stop.coordinate)
            if distance <= subwayRadius {
                subway.append((stop, distance))
            }
        }

        var bus: [(TransitStop, Double)] = []
        var expandedBusRadius = busRadius
        for _ in 0..<2 {
            bus.removeAll()
            let window = (expandedBusRadius + 200) / 111_000
            for stop in index.stops where stop.display && stop.mode != .subway {
                if abs(stop.lat - coordinate.latitude) > window { continue }
                let distance = walking.distanceMeters(coordinate, stop.coordinate)
                let limitRadius = stop.mode == .expressBus ? expandedBusRadius + 200 : expandedBusRadius
                if distance <= limitRadius {
                    bus.append((stop, distance))
                }
            }
            if bus.count >= 4 || expandedBusRadius >= 900 { break }
            expandedBusRadius = 900
        }

        let clustered = clusterSubway(subway)
        var points = clustered
        points.append(contentsOf: bus.map { makePoint(stops: [$0.0], distance: $0.1) })
        points.sort { lhs, rhs in
            if lhs.distanceMeters == rhs.distanceMeters { return lhs.name < rhs.name }
            return lhs.distanceMeters < rhs.distanceMeters
        }
        if points.count > limit {
            points = Array(points.prefix(limit))
        }
        return points
    }

    private func clusterSubway(_ stops: [(TransitStop, Double)]) -> [AccessPoint] {
        var remaining = stops.sorted { $0.1 < $1.1 }
        var clusters: [AccessPoint] = []
        while let seed = remaining.first {
            var group = [seed]
            remaining.removeFirst()
            var grew = true
            while grew {
                grew = false
                var index = 0
                while index < remaining.count {
                    let candidate = remaining[index]
                    let sameName = candidate.0.name == seed.0.name
                    let close = group.contains { member in
                        WalkingModel.nyc.distanceMeters(member.0.coordinate, candidate.0.coordinate) <= 340
                    }
                    if sameName && close {
                        group.append(candidate)
                        remaining.remove(at: index)
                        grew = true
                    } else {
                        index += 1
                    }
                }
            }
            let nearest = group.map(\.1).min() ?? 0
            clusters.append(makePoint(stops: group.map(\.0), distance: nearest))
        }
        return clusters
    }

    private func makePoint(stops: [TransitStop], distance: Double) -> AccessPoint {
        let ordered = stops.sorted { $0.id < $1.id }
        var routes: [String] = []
        var seen = Set<String>()
        for stop in stops {
            for route in stop.routes where seen.insert(route).inserted {
                routes.append(route)
            }
        }
        var platforms: [String] = []
        var platformSeen = Set<String>()
        for stop in ordered {
            let children = childIDsByParent[stop.id] ?? []
            let ids = children.isEmpty ? [stop.id] : children
            for id in ids where platformSeen.insert(id).inserted {
                platforms.append(id)
            }
        }
        let pin = stops[0]
        return AccessPoint(
            id: ordered.map(\.id).joined(separator: "+"),
            name: pin.name,
            coordinate: pin.coordinate,
            distanceMeters: distance,
            mode: stops.contains(where: { $0.mode == .subway }) ? .subway : (stops.allSatisfy { $0.mode == .expressBus } ? .expressBus : .localBus),
            routeIDs: routes,
            memberIDs: ordered.map(\.id),
            platformIDs: platforms
        )
    }
}

private struct Cell: Hashable, Sendable {
    let x: Int
    let y: Int

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    init(_ coordinate: Coordinate) {
        x = Int(floor(coordinate.latitude / 0.0025))
        y = Int(floor(coordinate.longitude / 0.0025))
    }
}

public enum CatalogLoader {
    public static func load(from url: URL) throws -> TransitCatalog {
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode(TransitIndex.self, from: data)
        return TransitCatalog(index: index)
    }

    public static func load(bundle: Bundle = .main, resource: String = "transit-index") throws -> TransitCatalog {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try load(from: url)
    }
}
