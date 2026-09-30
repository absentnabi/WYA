import Foundation

public enum GTFSRTError: Error, Equatable {
    case truncated
    case overflow
    case invalidWireType(Int)
}

/// Minimal GTFS-realtime reader for TripUpdates.
///
/// Field numbers follow the official `gtfs-realtime.proto` (proto2):
/// - FeedMessage.entity = 2, FeedEntity.trip_update = 3
/// - TripUpdate.trip = 1, TripUpdate.stop_time_update = 2
/// - TripDescriptor.route_id = 5, TripDescriptor.schedule_relationship = 4
/// - StopTimeUpdate.stop_id = 4, arrival = 2, departure = 3, schedule_relationship = 5
/// - StopTimeEvent.delay = 1, StopTimeEvent.time = 2
///
/// NYCT extensions (field 1001 and friends) are skipped. Absolute `time` is
/// required; delay alone is not turned into a clock time.
public enum GTFSRTParser {
    public static func parse(
        _ data: Data,
        interestingStopIDs: Set<String>?,
        now: Date
    ) throws -> [Arrival] {
        if data.isEmpty { return [] }
        if let interestingStopIDs, interestingStopIDs.isEmpty { return [] }
        let earliest = now.timeIntervalSince1970 - 30
        let latest = now.timeIntervalSince1970 + 3 * 3600
        var reader = Reader(data: data, offset: 0, end: data.count)
        var arrivals: [Arrival] = []
        try reader.forEachField { field, wire, reader in
            guard field == 2, wire == 2 else {
                try reader.skip(wire)
                return
            }
            var entity = try reader.nested()
            guard let update = try parseEntity(&entity) else { return }
            for stop in update.stops {
                guard let epoch = stop.epoch else { continue }
                if let interestingStopIDs, !interestingStopIDs.contains(stop.stopID) { continue }
                if epoch < earliest || epoch > latest { continue }
                arrivals.append(
                    Arrival(
                        routeID: update.routeID,
                        stopID: stop.stopID,
                        epoch: epoch,
                        destination: nil,
                        isSample: false
                    )
                )
                if arrivals.count >= 50_000 { return }
            }
        }
        return arrivals
    }

    private struct StopPrediction {
        var stopID: String
        var epoch: TimeInterval?
        var skipped = false
    }

    private struct TripPrediction {
        var routeID: String
        var canceled = false
        var stops: [StopPrediction] = []
    }

    private static func parseEntity(_ reader: inout Reader) throws -> TripPrediction? {
        var deleted = false
        var prediction: TripPrediction?
        try reader.forEachField { field, wire, reader in
            switch (field, wire) {
            case (2, 0):
                deleted = try reader.varint() != 0
            case (3, 2):
                var trip = try reader.nested()
                prediction = try parseTripUpdate(&trip)
            default:
                try reader.skip(wire)
            }
        }
        if deleted { return nil }
        guard let prediction, !prediction.canceled, !prediction.routeID.isEmpty else { return nil }
        return prediction
    }

    private static func parseTripUpdate(_ reader: inout Reader) throws -> TripPrediction {
        var prediction = TripPrediction(routeID: "")
        try reader.forEachField { field, wire, reader in
            switch (field, wire) {
            case (1, 2):
                var descriptor = try reader.nested()
                let (route, canceled) = try parseTripDescriptor(&descriptor)
                prediction.routeID = route
                prediction.canceled = canceled
            case (2, 2):
                var stop = try reader.nested()
                if let parsed = try parseStopTime(&stop) {
                    prediction.stops.append(parsed)
                }
            default:
                try reader.skip(wire)
            }
        }
        prediction.stops.removeAll { $0.skipped || $0.stopID.isEmpty }
        return prediction
    }

    private static func parseTripDescriptor(_ reader: inout Reader) throws -> (String, Bool) {
        var routeID = ""
        var canceled = false
        try reader.forEachField { field, wire, reader in
            switch (field, wire) {
            case (4, 0):
                let relationship = try reader.varint()
                if relationship == 3 || relationship == 7 { canceled = true }
            case (5, 2):
                routeID = try reader.string()
            default:
                try reader.skip(wire)
            }
        }
        return (routeID, canceled)
    }

    private static func parseStopTime(_ reader: inout Reader) throws -> StopPrediction? {
        var stop = StopPrediction(stopID: "")
        try reader.forEachField { field, wire, reader in
            switch (field, wire) {
            case (2, 2):
                var event = try reader.nested()
                if let time = try parseEventTime(&event) {
                    stop.epoch = stop.epoch ?? time
                }
            case (3, 2):
                var event = try reader.nested()
                if let time = try parseEventTime(&event), stop.epoch == nil {
                    stop.epoch = time
                }
            case (4, 2):
                stop.stopID = try reader.string()
            case (5, 0):
                let relationship = try reader.varint()
                if relationship == 1 { stop.skipped = true }
            default:
                try reader.skip(wire)
            }
        }
        return stop
    }

    private static func parseEventTime(_ reader: inout Reader) throws -> TimeInterval? {
        var time: TimeInterval?
        try reader.forEachField { field, wire, reader in
            // delay is field 1 and is intentionally ignored.
            if field == 2, wire == 0 {
                let raw = try reader.varint()
                let signed = Int64(bitPattern: raw)
                if signed > 1_000_000_000 {
                    time = TimeInterval(signed)
                }
            } else {
                try reader.skip(wire)
            }
        }
        return time
    }

    private struct Reader {
        let data: Data
        var offset: Int
        var end: Int
        var fieldsSeen = 0

        mutating func forEachField(_ body: (Int, Int, inout Reader) throws -> Void) throws {
            while offset < end {
                fieldsSeen += 1
                if fieldsSeen > 200_000 { throw GTFSRTError.overflow }
                let key = try varint()
                let field = Int(key >> 3)
                let wire = Int(key & 0x7)
                if field == 0 { throw GTFSRTError.invalidWireType(wire) }
                try body(field, wire, &self)
            }
        }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            for _ in 0..<10 {
                guard offset < end else { throw GTFSRTError.truncated }
                let byte = data[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            throw GTFSRTError.overflow
        }

        mutating func skip(_ wire: Int) throws {
            switch wire {
            case 0:
                _ = try varint()
            case 1:
                try advance(8)
            case 2:
                let length = try length()
                try advance(length)
            case 5:
                try advance(4)
            default:
                throw GTFSRTError.invalidWireType(wire)
            }
        }

        mutating func nested() throws -> Reader {
            let length = try length()
            guard offset + length <= end else { throw GTFSRTError.truncated }
            var child = Reader(data: data, offset: offset, end: offset + length)
            child.fieldsSeen = 0
            offset += length
            return child
        }

        mutating func string() throws -> String {
            let length = try length()
            guard offset + length <= end else { throw GTFSRTError.truncated }
            let slice = data.subdata(in: offset..<(offset + length))
            offset += length
            return String(decoding: slice, as: UTF8.self)
        }

        private mutating func length() throws -> Int {
            let value = try varint()
            guard value <= UInt64(Int.max) else { throw GTFSRTError.overflow }
            return Int(value)
        }

        private mutating func advance(_ count: Int) throws {
            guard count >= 0, offset + count <= end else { throw GTFSRTError.truncated }
            offset += count
        }
    }
}
