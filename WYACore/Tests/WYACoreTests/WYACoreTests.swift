import XCTest
@testable import WYACore

final class DurationAndWalkingTests: XCTestCase {
    func testRoundedMinutes() {
        XCTAssertEqual(DurationMath.roundedMinutes(0), 0)
        XCTAssertEqual(DurationMath.roundedMinutes(29), 0)
        XCTAssertEqual(DurationMath.roundedMinutes(30), 1)
        XCTAssertEqual(DurationMath.roundedMinutes(60), 1)
        XCTAssertEqual(DurationMath.roundedMinutes(90), 2)
    }

    func testDisplayMinutesAddUp() {
        let legs = [
            TripLeg(kind: .walk, seconds: 50, title: "Walk", detail: ""),
            TripLeg(kind: .wait, seconds: 180, title: "Wait", detail: ""),
            TripLeg(kind: .ride, seconds: 700, title: "Ride", detail: "")
        ]
        let parts = legs.map { DurationMath.roundedMinutes($0.seconds) }
        XCTAssertEqual(DurationMath.displayMinutes(legs: legs), parts.reduce(0, +))
        XCTAssertEqual(DurationMath.totalSeconds(legs), 930)
    }

    func testHaversineAndWalkSeconds() {
        let model = WalkingModel(metersPerSecond: 1, streetFactor: 1)
        let equator = model.distanceMeters(
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 1, longitude: 0)
        )
        XCTAssertEqual(equator, 6_371_000 * .pi / 180, accuracy: 1)
        XCTAssertEqual(model.seconds(from: Coordinate(latitude: 0, longitude: 0), to: Coordinate(latitude: 1, longitude: 0)), Int(equator.rounded()))
        XCTAssertEqual(model.seconds(from: Coordinate(latitude: 1, longitude: 1), to: Coordinate(latitude: 1, longitude: 1)), 0)
    }

    func testCountdownLabels() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(Arrival(routeID: "1", stopID: "A", epoch: 1_020, destination: nil, isSample: false).countdownLabel(at: now), "Now")
        XCTAssertEqual(Arrival(routeID: "1", stopID: "A", epoch: 1_090, destination: nil, isSample: false).countdownLabel(at: now), "1 min")
        XCTAssertEqual(Arrival(routeID: "1", stopID: "A", epoch: 1_300, destination: nil, isSample: false).countdownLabel(at: now), "5 min")
    }
}

final class RouteAndQueryTests: XCTestCase {
    func testClassifierMatchesGTFSRules() {
        XCTAssertEqual(RouteClassifier.mode(routeType: 1, shortName: "4", longName: "Lexington Avenue Express"), .subway)
        XCTAssertEqual(RouteClassifier.mode(routeType: 2, shortName: "SIR", longName: "Staten Island Railway"), .subway)
        XCTAssertEqual(RouteClassifier.mode(routeType: 3, shortName: "M15", longName: "Select Bus Service"), .localBus)
        XCTAssertEqual(RouteClassifier.mode(routeType: 3, shortName: "BM5", longName: "Spring Creek - Midtown"), .expressBus)
        XCTAssertEqual(RouteClassifier.mode(routeType: 3, shortName: "BxM10", longName: "Riverdale"), .expressBus)
        XCTAssertEqual(RouteClassifier.mode(routeType: 3, shortName: "SIM1C", longName: "Eltingville"), .expressBus)
        XCTAssertEqual(RouteClassifier.mode(routeType: 3, shortName: "Q10", longName: "JFK Airport Express"), .expressBus)
        XCTAssertNil(RouteClassifier.mode(routeType: 4, shortName: "Ferry", longName: "Ferry"))
    }

    func testQueryParser() {
        XCTAssertEqual(
            TripQueryParser.parse("from here to Grand Central"),
            ParsedTripQuery(origin: nil, destination: "Grand Central")
        )
        XCTAssertEqual(
            TripQueryParser.parse("From  Grand Central  to  JFK"),
            ParsedTripQuery(origin: "Grand Central", destination: "JFK")
        )
        XCTAssertEqual(
            TripQueryParser.parse("how do I get to the Brooklyn Museum"),
            ParsedTripQuery(origin: nil, destination: "the Brooklyn Museum")
        )
        XCTAssertEqual(
            TripQueryParser.parse("Barclays Center"),
            ParsedTripQuery(origin: nil, destination: "Barclays Center")
        )
        XCTAssertEqual(TripQueryParser.parse("   ").destination, nil)
    }

    func testSubwayFeedMap() {
        XCTAssertEqual(SubwayRealtimeFeed.feeds(containing: "6X"), [.numbered])
        XCTAssertEqual(SubwayRealtimeFeed.feeds(containing: "FX"), [.bdfm])
        XCTAssertEqual(SubwayRealtimeFeed.feeds(containing: "A"), [.ace])
        XCTAssertEqual(SubwayRealtimeFeed.feeds(containing: "SI"), [.statenIsland])
        XCTAssertEqual(Set(SubwayRealtimeFeed.feeds(containing: "FS")), Set([.ace, .numbered]))
        XCTAssertTrue(SubwayRealtimeFeed.numbered.url.absoluteString.contains("nyct%2Fgtfs"))
    }
}

final class RealtimeParserTests: XCTestCase {
    func testParsesTripUpdateTimeNotDelay() throws {
        let event = Proto.uint(2, 1_700_000_120)
        let unknown = Proto.message(1001, Proto.str(1, "track"))
        let stop = Proto.message(2, event) + Proto.str(4, "127N") + unknown
        let trip = Proto.str(1, "trip") + Proto.message(1001, Proto.str(1, "01 1800")) + Proto.str(5, "1")
        let update = Proto.message(1, trip) + Proto.message(2, stop)
        let entity = Proto.str(1, "e1") + Proto.message(3, update)
        let feed = Proto.message(1, Proto.str(1, "2.0")) + Proto.message(2, entity)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let arrivals = try GTFSRTParser.parse(feed, interestingStopIDs: ["127N"], now: now)
        XCTAssertEqual(arrivals.count, 1)
        XCTAssertEqual(arrivals[0].routeID, "1")
        XCTAssertEqual(arrivals[0].stopID, "127N")
        XCTAssertEqual(arrivals[0].epoch, 1_700_000_120)
        XCTAssertFalse(arrivals[0].isSample)
        XCTAssertEqual(arrivals[0].countdownLabel(at: now), "2 min")
    }

    func testDelayOnlyAndSkippedAndCanceledAreIgnored() throws {
        let delayOnly = stopUpdate(route: "A", stop: "A12N", event: Proto.uint(1, 90), relationship: nil)
        let skipped = stopUpdate(route: "A", stop: "A12N", event: Proto.uint(2, 1_700_000_200), relationship: 1)
        let canceledTrip = Proto.str(1, "t") + Proto.uint(4, 3) + Proto.str(5, "A")
        let canceledStop = Proto.message(2, Proto.uint(2, 1_700_000_200)) + Proto.str(4, "A12N")
        let canceled = Proto.message(2, Proto.str(1, "c") + Proto.message(3, Proto.message(1, canceledTrip) + Proto.message(2, canceledStop)))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = delayOnly + skipped + canceled
        let arrivals = try GTFSRTParser.parse(data, interestingStopIDs: nil, now: now)
        XCTAssertTrue(arrivals.isEmpty)
    }

    func testFiltersStopsAndTruncation() throws {
        let feed = stopUpdate(route: "L", stop: "L06N", event: Proto.uint(2, 1_700_000_400), relationship: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let missed = try GTFSRTParser.parse(feed, interestingStopIDs: ["L03N"], now: now)
        XCTAssertTrue(missed.isEmpty)
        XCTAssertThrowsError(try GTFSRTParser.parse(Data([0x0A]), interestingStopIDs: nil, now: now))
    }

    func testRandomBytesDoNotTrap() {
        var generator = SplitMix(seed: 42)
        for _ in 0..<40 {
            var bytes = [UInt8]()
            let count = Int(generator.next() % 120)
            for _ in 0..<count { bytes.append(UInt8(generator.next() & 0xFF)) }
            do {
                _ = try GTFSRTParser.parse(Data(bytes), interestingStopIDs: nil, now: Date(timeIntervalSince1970: 1_700_000_000))
            } catch {
                continue
            }
        }
    }

    func testSIRIParsing() throws {
        let json = """
        {"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[{"MonitoredStopVisit":[
          {"MonitoredVehicleJourney":{"LineRef":"MTA NYCT_M15","PublishedLineName":"M15","DestinationName":"South Ferry","MonitoredCall":{"ExpectedArrivalTime":"2026-09-30T22:05:00Z"}}},
          {"MonitoredVehicleJourney":{"LineRef":"MTA NYCT_M15-SBS","PublishedLineName":["M15-SBS"],"DestinationName":["South Ferry"],"MonitoredCall":{"AimedArrivalTime":"2026-09-30T22:12:30.000Z"}}}
        ]}]}}}
        """.data(using: .utf8)!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = formatter.date(from: "2026-09-30T22:00:00Z")!
        let arrivals = try SIRIParser.parse(json: json, monitoredStopID: "403365", now: now)
        XCTAssertEqual(arrivals.map(\.routeID), ["M15", "M15-SBS"])
        XCTAssertEqual(arrivals[0].destination, "South Ferry")
        XCTAssertEqual(arrivals[0].stopID, "403365")
        XCTAssertEqual(arrivals[0].countdownLabel(at: now), "5 min")
        XCTAssertEqual(arrivals[1].countdownLabel(at: now), "12 min")
    }

    private func stopUpdate(route: String, stop: String, event: Data, relationship: UInt64?) -> Data {
        var stopMessage = Proto.message(2, event) + Proto.str(4, stop)
        if let relationship {
            stopMessage += Proto.uint(5, relationship)
        }
        let trip = Proto.str(5, route)
        let update = Proto.message(1, trip) + Proto.message(2, stopMessage)
        let entity = Proto.str(1, route + stop) + Proto.message(3, update)
        return Proto.message(2, entity)
    }
}

final class TripEstimatorTests: XCTestCase {
    func testDirectRideUsesScheduleAndTypicalWait() {
        let catalog = sampleCatalog(includeDirect: true)
        let estimator = TripEstimator(catalog: catalog, walking: WalkingModel(metersPerSecond: 1, streetFactor: 1))
        let plans = estimator.plans(
            from: Coordinate(latitude: 40, longitude: -74),
            originName: "A",
            to: Coordinate(latitude: 40.05, longitude: -74),
            destinationName: "C",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let plan = try! XCTUnwrap(plans.first)
        XCTAssertEqual(plan.legs.map(\.kind), [.wait, .ride])
        XCTAssertEqual(plan.legs[0].seconds, WaitEstimate.subway)
        XCTAssertFalse(plan.legs[0].live)
        XCTAssertEqual(plan.legs[1].seconds, 700)
        XCTAssertEqual(plan.legs[1].routeID, "1")
        XCTAssertEqual(plan.totalSeconds, 880)
        XCTAssertTrue(plan.summary.contains("1 toward South Ferry"))
        XCTAssertTrue(plan.summary.contains("total"))
    }

    func testLiveArrivalReplacesTypicalWait() {
        let catalog = sampleCatalog(includeDirect: true)
        let estimator = TripEstimator(catalog: catalog, walking: WalkingModel(metersPerSecond: 1, streetFactor: 1))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let plans = estimator.plans(
            from: Coordinate(latitude: 40, longitude: -74),
            originName: "A",
            to: Coordinate(latitude: 40.05, longitude: -74),
            destinationName: "C",
            at: now,
            liveArrivals: [LiveArrivalHint(stopID: "AN", routeID: "1", arrival: now.addingTimeInterval(60))]
        )
        let plan = try! XCTUnwrap(plans.first)
        XCTAssertEqual(plan.legs[0].seconds, 60)
        XCTAssertTrue(plan.legs[0].live)
        XCTAssertEqual(plan.totalSeconds, 760)
    }

    func testOneTransferWhenNoDirectRide() {
        let catalog = sampleCatalog(includeDirect: false)
        let estimator = TripEstimator(catalog: catalog, walking: WalkingModel(metersPerSecond: 1, streetFactor: 1))
        let plans = estimator.plans(
            from: Coordinate(latitude: 40, longitude: -74),
            originName: "A",
            to: Coordinate(latitude: 40.05, longitude: -74),
            destinationName: "C",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let plan = try! XCTUnwrap(plans.first)
        XCTAssertEqual(plan.legs.map(\.routeID), [Optional("1"), Optional("1"), nil, Optional("2"), Optional("2")])
        XCTAssertEqual(plan.legs.map(\.kind), [.wait, .ride, .walk, .wait, .ride])
        XCTAssertEqual(plan.legs[2].seconds, WaitEstimate.sameStopTransfer)
        XCTAssertEqual(plan.totalSeconds, 180 + 300 + 45 + 180 + 400)
    }

    func testNearbyClustersSameStationNameAndSortsByDistance() {
        let catalog = sampleCatalog(includeDirect: true)
        let points = catalog.nearby(to: Coordinate(latitude: 40, longitude: -74), subwayRadius: 20_000, busRadius: 20_000, limit: 10)
        XCTAssertEqual(points.map(\.name), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(points[0].routeIDs, ["1", "L"])
        XCTAssertTrue(points[0].distanceMeters < points[1].distanceMeters)
    }

    func testFixturesAreStableAndInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = FixtureArrivals.make(stopID: "635", routeIDs: ["4", "6"], now: now)
        let second = FixtureArrivals.make(stopID: "635", routeIDs: ["4", "6"], now: now)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isSample && $0.epoch > now.timeIntervalSince1970 })
        XCTAssertEqual(Set(first.map(\.routeID)), Set(["4", "6"]))
    }

    private func sampleCatalog(includeDirect: Bool) -> TransitCatalog {
        func stop(_ id: String, _ name: String, _ lat: Double, routes: [String], parent: String? = nil, display: Bool, mode: TransitMode = .subway) -> TransitStop {
            TransitStop(id: id, name: name, lat: lat, lon: -74, mode: mode, parent: parent, routes: routes, display: display)
        }
        let stops = [
            stop("A", "Alpha", 40.00, routes: ["1", "L"], display: true),
            stop("AN", "Alpha", 40.00, routes: ["1"], parent: "A", display: false),
            stop("AL", "Alpha", 40.0004, routes: ["L"], parent: "A2", display: false),
            stop("A2", "Alpha", 40.0004, routes: ["L"], display: true),
            stop("B", "Beta", 40.02, routes: ["1", "2"], display: true),
            stop("BN", "Beta", 40.02, routes: ["1", "2"], parent: "B", display: false),
            stop("C", "Gamma", 40.05, routes: ["1", "2"], display: true),
            stop("CN", "Gamma", 40.05, routes: ["1", "2"], parent: "C", display: false)
        ]
        let routes = [
            TransitRoute(id: "1", shortName: "1", longName: "Local", mode: .subway, color: "D82233", textColor: "FFFFFF"),
            TransitRoute(id: "2", shortName: "2", longName: "Express", mode: .subway, color: "D82233", textColor: "FFFFFF"),
            TransitRoute(id: "L", shortName: "L", longName: "Canarsie", mode: .subway, color: "7C858C", textColor: "FFFFFF")
        ]
        var firstStops = [
            PatternStop(id: "AN", cumulativeSeconds: 0),
            PatternStop(id: "BN", cumulativeSeconds: 300)
        ]
        if includeDirect {
            firstStops.append(PatternStop(id: "CN", cumulativeSeconds: 700))
        }
        let patterns = [
            RoutePattern(route: "1", direction: 1, headsign: "South Ferry", stops: firstStops),
            RoutePattern(route: "2", direction: 0, headsign: "Flatbush", stops: [
                PatternStop(id: "BN", cumulativeSeconds: 0),
                PatternStop(id: "CN", cumulativeSeconds: 400)
            ]),
            RoutePattern(route: "L", direction: 0, headsign: "Canarsie", stops: [
                PatternStop(id: "AL", cumulativeSeconds: 0)
            ])
        ]
        let index = TransitIndex(
            generated: "test",
            source: "fixture",
            feeds: [],
            stops: stops,
            routes: routes,
            patterns: patterns
        )
        return TransitCatalog(index: index)
    }
}

final class TransitIndexIntegrationTests: XCTestCase {
    func testBundledIndexConnectsUnionSquareToGrandCentral() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("WYA/Resources/transit-index.json")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("transit-index.json is not readable from this test process")
        }
        let catalog = try CatalogLoader.load(from: url)
        XCTAssertGreaterThan(catalog.index.routes.filter { $0.mode == .subway }.count, 20)
        XCTAssertGreaterThan(catalog.index.stops.filter { $0.display && $0.mode != .subway }.count, 5_000)

        let union = Coordinate(latitude: 40.735736, longitude: -73.990568)
        let nearby = catalog.nearby(to: union, subwayRadius: 600, busRadius: 400, limit: 12)
        XCTAssertFalse(nearby.isEmpty)
        XCTAssertLessThan(nearby[0].distanceMeters, nearby.last!.distanceMeters + 0.1)
        XCTAssertTrue(nearby.contains { $0.name.contains("14 St-Union Sq") && $0.routeIDs.contains("6") })

        guard let origin = catalog.index.stops.first(where: { $0.id == "635" }),
              let destination = catalog.index.stops.first(where: { $0.id == "631" })
        else {
            return XCTFail("Expected Lexington Ave stations in the index")
        }
        let plans = TripEstimator(catalog: catalog).plans(
            from: origin.coordinate,
            originName: origin.name,
            to: destination.coordinate,
            destinationName: destination.name,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let plan = try XCTUnwrap(plans.first)
        let ride = try XCTUnwrap(plan.legs.first { $0.kind == .ride })
        XCTAssertTrue(["4", "5", "6", "6X"].contains(ride.routeID))
        XCTAssertGreaterThan(plan.totalSeconds, 5 * 60)
        XCTAssertLessThan(plan.totalSeconds, 35 * 60)
        XCTAssertEqual(plan.totalSeconds, DurationMath.totalSeconds(plan.legs))
        XCTAssertTrue(plan.summary.localizedCaseInsensitiveContains("total"))
    }
}

private enum Proto {
    static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var out = Data()
        while true {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            out.append(byte)
            if remaining == 0 { break }
        }
        return out
    }

    static func key(_ field: Int, _ wire: Int) -> Data { varint(UInt64(field << 3 | wire)) }
    static func message(_ field: Int, _ payload: Data) -> Data { key(field, 2) + varint(UInt64(payload.count)) + payload }
    static func str(_ field: Int, _ text: String) -> Data { message(field, Data(text.utf8)) }
    static func uint(_ field: Int, _ value: UInt64) -> Data { key(field, 0) + varint(value) }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
