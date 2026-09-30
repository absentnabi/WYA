import Foundation

public struct TripEstimator: Sendable {
    public let catalog: TransitCatalog
    public var walking: WalkingModel

    public init(catalog: TransitCatalog, walking: WalkingModel = .nyc) {
        self.catalog = catalog
        self.walking = walking
    }

    public func plans(
        from origin: Coordinate,
        originName: String,
        to destination: Coordinate,
        destinationName: String,
        at now: Date,
        liveArrivals: [LiveArrivalHint] = []
    ) -> [TripPlan] {
        let separation = walking.distanceMeters(origin, destination)
        if separation < 80 {
            let leg = TripLeg(
                kind: .walk,
                seconds: walking.seconds(from: origin, to: destination),
                title: "You're already there",
                detail: destinationName,
                from: origin,
                to: destination
            )
            return [TripPlan(originName: originName, destinationName: destinationName, legs: [leg])]
        }

        let originAccess = catalog.nearby(to: origin, subwayRadius: 1100, busRadius: 850, limit: 8)
        let destinationAccess = catalog.nearby(to: destination, subwayRadius: 1000, busRadius: 800, limit: 8)
        guard !originAccess.isEmpty, !destinationAccess.isEmpty else {
            return walkOnly(origin: origin, originName: originName, destination: destination, destinationName: destinationName)
        }

        let originIDs = idSet(originAccess)
        let destinationIDs = idSet(destinationAccess)
        var reachers = Set<Int>()
        for id in destinationIDs {
            for hit in catalog.hits(forStop: id) {
                reachers.insert(hit.pattern)
            }
        }
        var bestByKey: [String: TripPlan] = [:]

        var patternIDs = Set<Int>()
        for id in originIDs {
            for hit in catalog.hits(forStop: id) {
                patternIDs.insert(hit.pattern)
            }
        }

        for patternIndex in patternIDs {
            let pattern = catalog.index.patterns[patternIndex]
            let boards = matchingIndexes(pattern, ids: originIDs)
            let alights = matchingIndexes(pattern, ids: destinationIDs)
            guard !boards.isEmpty else { continue }
            for board in boards {
                if let alight = alights.first(where: { $0 > board }) {
                    consider(
                        direct: patternIndex,
                        board: board,
                        alight: alight,
                        origin: origin,
                        originName: originName,
                        destination: destination,
                        destinationName: destinationName,
                        now: now,
                        liveArrivals: liveArrivals,
                        into: &bestByKey
                    )
                }
                considerTransfers(
                    patternIndex: patternIndex,
                    board: board,
                    destinationIDs: destinationIDs,
                    reachers: reachers,
                    origin: origin,
                    originName: originName,
                    destination: destination,
                    destinationName: destinationName,
                    now: now,
                    liveArrivals: liveArrivals,
                    into: &bestByKey
                )
            }
        }

        var ranked = bestByKey.values.sorted { $0.totalSeconds < $1.totalSeconds }
        let walk = walkOnly(origin: origin, originName: originName, destination: destination, destinationName: destinationName)
        if let only = walk.first {
            if ranked.isEmpty || only.totalSeconds + 180 < ranked[0].totalSeconds {
                ranked.append(only)
            }
        }
        if ranked.count > 3 { ranked = Array(ranked.prefix(3)) }
        return ranked
    }

    private func consider(
        direct patternIndex: Int,
        board: Int,
        alight: Int,
        origin: Coordinate,
        originName: String,
        destination: Coordinate,
        destinationName: String,
        now: Date,
        liveArrivals: [LiveArrivalHint],
        into best: inout [String: TripPlan]
    ) {
        let pattern = catalog.index.patterns[patternIndex]
        guard let boardStop = catalog.stopsByID[pattern.stops[board].id],
              let alightStop = catalog.stopsByID[pattern.stops[alight].id],
              let route = catalog.routesByID[pattern.route]
        else { return }
        let ride = max(30, pattern.stops[alight].cumulativeSeconds - pattern.stops[board].cumulativeSeconds)
        guard ride < 3 * 3600 else { return }
        let wait = waitSeconds(route: route, stop: boardStop, now: now, liveArrivals: liveArrivals)
        var legs: [TripLeg] = []
        appendWalk(legs: &legs, from: origin, to: boardStop.coordinate, title: "Walk to \(boardStop.name)")
        legs.append(waitLeg(route: route, wait: wait))
        legs.append(rideLeg(route: route, pattern: pattern, from: boardStop, to: alightStop, seconds: ride))
        appendWalk(legs: &legs, from: alightStop.coordinate, to: destination, title: "Walk to \(destinationName)")
        let key = "\(route.id)|\(placeKey(boardStop))>\(placeKey(alightStop))"
        store(legs: legs, key: key, originName: originName, destinationName: destinationName, into: &best)
    }

    private func considerTransfers(
        patternIndex: Int,
        board: Int,
        destinationIDs: Set<String>,
        reachers: Set<Int>,
        origin: Coordinate,
        originName: String,
        destination: Coordinate,
        destinationName: String,
        now: Date,
        liveArrivals: [LiveArrivalHint],
        into best: inout [String: TripPlan]
    ) {
        let pattern = catalog.index.patterns[patternIndex]
        guard let boardStop = catalog.stopsByID[pattern.stops[board].id],
              let firstRoute = catalog.routesByID[pattern.route]
        else { return }
        let upper = min(pattern.stops.count, board + 35)
        guard board + 1 < upper else { return }
        for transferIndex in (board + 1)..<upper {
            guard let transferStop = catalog.stopsByID[pattern.stops[transferIndex].id] else { continue }
            let firstRide = pattern.stops[transferIndex].cumulativeSeconds - pattern.stops[board].cumulativeSeconds
            guard firstRide >= 30 else { continue }
            var seenPatterns = Set<Int>()
            for hit in connectionHits(at: transferStop) {
                if hit.pattern == patternIndex || !reachers.contains(hit.pattern) || !seenPatterns.insert(hit.pattern).inserted { continue }
                let next = catalog.index.patterns[hit.pattern]
                if next.route == pattern.route { continue }
                guard next.stops.indices.contains(hit.stopIndex) else { continue }
                guard let alightIndex = matchingIndexes(next, ids: destinationIDs).first(where: { $0 > hit.stopIndex }) else { continue }
                guard let nextBoard = catalog.stopsByID[next.stops[hit.stopIndex].id],
                      let alightStop = catalog.stopsByID[next.stops[alightIndex].id],
                      let secondRoute = catalog.routesByID[next.route]
                else { continue }
                let secondRide = next.stops[alightIndex].cumulativeSeconds - next.stops[hit.stopIndex].cumulativeSeconds
                guard secondRide >= 30, secondRide < 3 * 3600 else { continue }
                let firstWait = waitSeconds(route: firstRoute, stop: boardStop, now: now, liveArrivals: liveArrivals)
                let secondWait = waitSeconds(route: secondRoute, stop: nextBoard, now: now, liveArrivals: liveArrivals)
                var legs: [TripLeg] = []
                appendWalk(legs: &legs, from: origin, to: boardStop.coordinate, title: "Walk to \(boardStop.name)")
                legs.append(waitLeg(route: firstRoute, wait: firstWait))
                legs.append(rideLeg(route: firstRoute, pattern: pattern, from: boardStop, to: transferStop, seconds: firstRide))
                legs.append(transferLeg(from: transferStop, to: nextBoard))
                legs.append(waitLeg(route: secondRoute, wait: secondWait))
                legs.append(rideLeg(route: secondRoute, pattern: next, from: nextBoard, to: alightStop, seconds: secondRide))
                appendWalk(legs: &legs, from: alightStop.coordinate, to: destination, title: "Walk to \(destinationName)")
                let key = "\(firstRoute.id)>\(secondRoute.id)|\(placeKey(boardStop))>\(placeKey(transferStop))>\(placeKey(alightStop))"
                store(legs: legs, key: key, originName: originName, destinationName: destinationName, into: &best)
            }
        }
    }

    private func connectionHits(at stop: TransitStop) -> [PatternHit] {
        var seen = Set<PatternHit>()
        var hits: [PatternHit] = []
        func add(_ list: [PatternHit]) {
            for hit in list where seen.insert(hit).inserted {
                hits.append(hit)
            }
        }
        add(catalog.hits(forStop: stop.id))
        if let parent = stop.parent {
            add(catalog.hits(forStop: parent))
        }
        add(catalog.hits(near: stop.coordinate, radius: 280))
        return hits
    }

    private func store(
        legs: [TripLeg],
        key: String,
        originName: String,
        destinationName: String,
        into best: inout [String: TripPlan]
    ) {
        let plan = TripPlan(originName: originName, destinationName: destinationName, legs: legs)
        if plan.totalSeconds > 4 * 3600 { return }
        if let existing = best[key] {
            if existing.totalSeconds <= plan.totalSeconds { return }
            best[key] = plan
            return
        }
        if best.count >= 24, let worst = best.max(by: { $0.value.totalSeconds < $1.value.totalSeconds }) {
            if plan.totalSeconds >= worst.value.totalSeconds { return }
            best.removeValue(forKey: worst.key)
        }
        best[key] = plan
    }

    private func idSet(_ points: [AccessPoint]) -> Set<String> {
        var ids = Set<String>()
        for point in points {
            ids.formUnion(point.memberIDs)
            ids.formUnion(point.platformIDs)
        }
        return ids
    }

    private func matchingIndexes(_ pattern: RoutePattern, ids: Set<String>) -> [Int] {
        pattern.stops.enumerated().compactMap { index, stop in
            if ids.contains(stop.id) { return index }
            if let parent = catalog.parentID(for: stop.id), ids.contains(parent) { return index }
            return nil
        }
    }

    private func waitSeconds(
        route: TransitRoute,
        stop: TransitStop,
        now: Date,
        liveArrivals: [LiveArrivalHint]
    ) -> (seconds: Int, live: Bool) {
        let place = placeKey(stop)
        var best: TimeInterval?
        for hint in liveArrivals where hint.routeID == route.id {
            let hintPlace = catalog.parentID(for: hint.stopID) ?? hint.stopID
            let same = hint.stopID == stop.id || hintPlace == place || hint.stopID == place
            guard same else { continue }
            let delta = hint.arrival.timeIntervalSince(now)
            if delta < -20 || delta > 45 * 60 { continue }
            if best == nil || delta < best! { best = delta }
        }
        if let best {
            return (max(0, Int(best.rounded())), true)
        }
        return (WaitEstimate.typical(for: route.mode), false)
    }

    private func waitLeg(route: TransitRoute, wait: (seconds: Int, live: Bool)) -> TripLeg {
        let detail = wait.live
            ? "Next \(route.shortName) from the live feed."
            : "Typical wait, not a live arrival."
        return TripLeg(
            kind: .wait,
            seconds: wait.seconds,
            title: "Wait for the \(route.shortName)",
            detail: detail,
            routeID: route.id,
            mode: route.mode,
            live: wait.live
        )
    }

    private func rideLeg(
        route: TransitRoute,
        pattern: RoutePattern,
        from: TransitStop,
        to: TransitStop,
        seconds: Int
    ) -> TripLeg {
        let toward = pattern.headsign.isEmpty ? route.shortName : pattern.headsign
        return TripLeg(
            kind: .ride,
            seconds: seconds,
            title: "\(route.shortName) toward \(toward)",
            detail: "\(from.name) to \(to.name)",
            routeID: route.id,
            mode: route.mode,
            from: from.coordinate,
            to: to.coordinate
        )
    }

    private func transferLeg(from: TransitStop, to: TransitStop) -> TripLeg {
        let seconds: Int
        if from.id == to.id {
            seconds = WaitEstimate.sameStopTransfer
        } else if placeKey(from) == placeKey(to) {
            seconds = WaitEstimate.sameStationTransfer
        } else {
            seconds = max(60, walking.seconds(from: from.coordinate, to: to.coordinate))
        }
        return TripLeg(
            kind: .walk,
            seconds: seconds,
            title: "Transfer at \(from.name)",
            detail: "Walk between vehicles",
            from: from.coordinate,
            to: to.coordinate
        )
    }

    private func appendWalk(legs: inout [TripLeg], from: Coordinate, to: Coordinate, title: String) {
        let seconds = walking.seconds(from: from, to: to)
        guard seconds >= 30 else { return }
        legs.append(TripLeg(kind: .walk, seconds: seconds, title: title, detail: "Distance estimate", from: from, to: to))
    }

    private func placeKey(_ stop: TransitStop) -> String {
        stop.parent ?? stop.id
    }

    private func walkOnly(
        origin: Coordinate,
        originName: String,
        destination: Coordinate,
        destinationName: String
    ) -> [TripPlan] {
        let seconds = walking.seconds(from: origin, to: destination)
        guard seconds > 0, seconds <= 90 * 60 else { return [] }
        let leg = TripLeg(
            kind: .walk,
            seconds: seconds,
            title: "Walk to \(destinationName)",
            detail: "No transit used",
            from: origin,
            to: destination
        )
        return [TripPlan(originName: originName, destinationName: destinationName, legs: [leg])]
    }
}
