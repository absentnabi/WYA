import Foundation

public struct Coordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum TransitMode: String, Codable, Sendable, CaseIterable {
    case subway
    case localBus
    case expressBus

    public var label: String {
        switch self {
        case .subway: return "Subway"
        case .localBus: return "Local bus"
        case .expressBus: return "Express bus"
        }
    }
}

public struct TransitStop: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let lat: Double
    public let lon: Double
    public let mode: TransitMode
    public let parent: String?
    public let routes: [String]
    public let display: Bool

    public var coordinate: Coordinate {
        Coordinate(latitude: lat, longitude: lon)
    }
}

public struct TransitRoute: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let shortName: String
    public let longName: String
    public let mode: TransitMode
    public let color: String
    public let textColor: String
}

public struct PatternStop: Codable, Hashable, Sendable {
    public let id: String
    public let cumulativeSeconds: Int

    enum CodingKeys: String, CodingKey {
        case id
        case cumulativeSeconds = "t"
    }
}

public struct RoutePattern: Codable, Hashable, Sendable {
    public let route: String
    public let direction: Int
    public let headsign: String
    public let stops: [PatternStop]
}

public struct FeedCredit: Codable, Hashable, Sendable {
    public let name: String
    public let url: String
}

public struct TransitIndex: Codable, Sendable {
    public let generated: String
    public let source: String
    public let feeds: [FeedCredit]
    public let stops: [TransitStop]
    public let routes: [TransitRoute]
    public let patterns: [RoutePattern]
}

public struct Arrival: Sendable, Equatable, Identifiable {
    public var id: String { "\(routeID)|\(stopID)|\(Int(epoch.rounded()))" }
    public let routeID: String
    public let stopID: String
    public let epoch: TimeInterval
    public let destination: String?
    public let isSample: Bool

    public init(routeID: String, stopID: String, epoch: TimeInterval, destination: String?, isSample: Bool) {
        self.routeID = routeID
        self.stopID = stopID
        self.epoch = epoch
        self.destination = destination
        self.isSample = isSample
    }

    public var date: Date { Date(timeIntervalSince1970: epoch) }

    /// Whole minutes until arrival, counting down. Under a minute is "Now".
    public func countdownLabel(at now: Date) -> String {
        let seconds = epoch - now.timeIntervalSince1970
        if seconds < 60 { return "Now" }
        let minutes = Int(seconds / 60.0)
        if minutes <= 1 { return "1 min" }
        return "\(minutes) min"
    }
}

public struct LiveArrivalHint: Sendable, Equatable {
    public let stopID: String
    public let routeID: String
    public let arrival: Date

    public init(stopID: String, routeID: String, arrival: Date) {
        self.stopID = stopID
        self.routeID = routeID
        self.arrival = arrival
    }
}

public struct TripLeg: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case walk
        case wait
        case ride
    }

    public let kind: Kind
    public var seconds: Int
    public let title: String
    public var detail: String
    public let routeID: String?
    public let mode: TransitMode?
    public let live: Bool
    public var from: Coordinate?
    public var to: Coordinate?

    public init(
        kind: Kind,
        seconds: Int,
        title: String,
        detail: String,
        routeID: String? = nil,
        mode: TransitMode? = nil,
        live: Bool = false,
        from: Coordinate? = nil,
        to: Coordinate? = nil
    ) {
        self.kind = kind
        self.seconds = seconds
        self.title = title
        self.detail = detail
        self.routeID = routeID
        self.mode = mode
        self.live = live
        self.from = from
        self.to = to
    }
}

public struct TripPlan: Sendable, Identifiable {
    public let id: UUID
    public let originName: String
    public let destinationName: String
    public var legs: [TripLeg]

    public init(id: UUID = UUID(), originName: String, destinationName: String, legs: [TripLeg]) {
        self.id = id
        self.originName = originName
        self.destinationName = destinationName
        self.legs = legs
    }

    public var totalSeconds: Int { DurationMath.totalSeconds(legs) }
    public var displayMinutes: Int { DurationMath.displayMinutes(legs: legs) }
    public var summary: String {
        TripNarration.summarize(origin: originName, destination: destinationName, legs: legs)
    }
}

public enum DurationMath {
    public static func roundedMinutes(_ seconds: Int) -> Int {
        guard seconds > 0 else { return 0 }
        return Int((Double(seconds) / 60.0).rounded())
    }

    public static func totalSeconds(_ legs: [TripLeg]) -> Int {
        legs.reduce(0) { $0 + max(0, $1.seconds) }
    }

    /// Sum of each leg rounded to a minute, so the breakdown adds up to the headline.
    public static func displayMinutes(legs: [TripLeg]) -> Int {
        let sum = legs.reduce(0) { $0 + roundedMinutes(max(0, $1.seconds)) }
        if sum == 0 && totalSeconds(legs) > 0 { return 1 }
        return sum
    }

    public static func spoken(_ seconds: Int) -> String {
        let minutes = roundedMinutes(seconds)
        if minutes <= 0 { return "under a minute" }
        if minutes == 1 { return "1 minute" }
        return "\(minutes) minutes"
    }
}

public enum TripNarration {
    public static func summarize(origin: String, destination: String, legs: [TripLeg]) -> String {
        if legs.count == 1, legs[0].kind == .walk, legs[0].seconds < 45 {
            return "You're already at \(destination)."
        }
        var sentences: [String] = []
        for leg in legs {
            let timing = DurationMath.spoken(leg.seconds)
            switch leg.kind {
            case .walk:
                sentences.append("\(leg.title) (\(timing)).")
            case .wait:
                if leg.live {
                    sentences.append("Wait \(timing). \(leg.detail)")
                } else {
                    sentences.append("Allow \(timing) to wait. \(leg.detail)")
                }
            case .ride:
                sentences.append("\(leg.title) (\(timing)).")
            }
        }
        let total = DurationMath.displayMinutes(legs: legs)
        let totalWords = total == 1 ? "1 minute" : "\(total) minutes"
        sentences.append("About \(totalWords) total, including walking, from \(origin) to \(destination).")
        return sentences.joined(separator: " ")
    }
}

public struct ParsedTripQuery: Equatable, Sendable {
    public var origin: String?
    public var destination: String?

    public init(origin: String?, destination: String?) {
        self.origin = origin
        self.destination = destination
    }
}

public enum TripQueryParser {
    public static func parse(_ raw: String) -> ParsedTripQuery {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !text.isEmpty else { return ParsedTripQuery(origin: nil, destination: nil) }

        let patterns: [(String, (NSTextCheckingResult, String) -> ParsedTripQuery)] = [
            ("(?i)^from\\s+(.+?)\\s+to\\s+(.+)$", { match, source in
                ParsedTripQuery(
                    origin: place(capture(match, 1, source)),
                    destination: place(capture(match, 2, source), allowHere: false)
                )
            }),
            ("(?i)^(get me to|take me to|how do i get to|how to get to|directions to|go to)\\s+(.+)$", { match, source in
                ParsedTripQuery(origin: nil, destination: place(capture(match, 2, source), allowHere: false))
            }),
            ("(?i)^to\\s+(.+)$", { match, source in
                ParsedTripQuery(origin: nil, destination: place(capture(match, 1, source), allowHere: false))
            })
        ]

        for (pattern, build) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), match.range.location != NSNotFound {
                let parsed = build(match, text)
                if parsed.destination?.isEmpty == false {
                    return parsed
                }
            }
        }
        return ParsedTripQuery(origin: nil, destination: place(text, allowHere: false))
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> String {
        guard let range = Range(match.range(at: index), in: source) else { return "" }
        return String(source[range])
    }

    private static func place(_ raw: String?, allowHere: Bool = true) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasSuffix(".") { text.removeLast() }
        let folded = text.lowercased()
        let here = ["here", "my location", "current location", "me", "where i am"]
        if allowHere && here.contains(folded) { return nil }
        if here.contains(folded) { return nil }
        return text
    }
}

/// Keep prefix rules aligned with `Scripts/build_transit_index.py`.
public enum RouteClassifier {
    public static let expressPrefixes = ["SIM", "QM", "BxM", "BM", "X"]

    public static func isExpress(shortName: String, longName: String) -> Bool {
        let compact = shortName.replacingOccurrences(of: " ", with: "")
        for prefix in expressPrefixes where compact.hasPrefix(prefix) {
            let rest = compact.dropFirst(prefix.count)
            if rest.first?.isNumber == true { return true }
        }
        return longName.range(of: "express", options: .caseInsensitive) != nil
    }

    public static func mode(routeType: Int, shortName: String, longName: String) -> TransitMode? {
        if routeType == 1 || routeType == 2 { return .subway }
        guard routeType == 3 else { return nil }
        return isExpress(shortName: shortName, longName: longName) ? .expressBus : .localBus
    }
}

public struct WalkingModel: Sendable {
    public var metersPerSecond: Double
    public var streetFactor: Double

    public init(metersPerSecond: Double = 1.30, streetFactor: Double = 1.25) {
        self.metersPerSecond = metersPerSecond
        self.streetFactor = streetFactor
    }

    public static let nyc = WalkingModel()

    public func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }

    public func seconds(from: Coordinate, to: Coordinate) -> Int {
        let meters = distanceMeters(from, to) * streetFactor
        if meters < 20 { return 0 }
        return Int((meters / max(0.5, metersPerSecond)).rounded())
    }
}

public enum WaitEstimate {
    public static let subway = 180
    public static let localBus = 420
    public static let expressBus = 720
    public static let sameStopTransfer = 45
    public static let sameStationTransfer = 150

    public static func typical(for mode: TransitMode) -> Int {
        switch mode {
        case .subway: return subway
        case .localBus: return localBus
        case .expressBus: return expressBus
        }
    }
}

public enum SubwayRealtimeFeed: String, CaseIterable, Sendable {
    case numbered
    case ace
    case bdfm
    case g
    case jz
    case nqrw
    case l
    case statenIsland

    public var path: String {
        switch self {
        case .numbered: return "nyct%2Fgtfs"
        case .ace: return "nyct%2Fgtfs-ace"
        case .bdfm: return "nyct%2Fgtfs-bdfm"
        case .g: return "nyct%2Fgtfs-g"
        case .jz: return "nyct%2Fgtfs-jz"
        case .nqrw: return "nyct%2Fgtfs-nqrw"
        case .l: return "nyct%2Fgtfs-l"
        case .statenIsland: return "nyct%2Fgtfs-si"
        }
    }

    public var url: URL {
        URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/\(path)")!
    }

    /// FS and H have moved between the ACE feed and the numbered feed in public
    /// client maps, so callers should request both.
    public static func feeds(containing routeID: String) -> [SubwayRealtimeFeed] {
        switch routeID {
        case "1", "2", "3", "4", "5", "6", "6X", "7", "7X", "GS":
            return [.numbered]
        case "FS", "H":
            return [.ace, .numbered]
        case "A", "C", "E":
            return [.ace]
        case "B", "D", "F", "FX", "M":
            return [.bdfm]
        case "G":
            return [.g]
        case "J", "Z":
            return [.jz]
        case "N", "Q", "R", "W":
            return [.nqrw]
        case "L":
            return [.l]
        case "SI":
            return [.statenIsland]
        default:
            return []
        }
    }
}

public enum CatalogError: Error, Equatable {
    case missingResource
    case unreadable
}
