import Foundation

public enum SIRIError: Error, Equatable {
    case malformed
    case noDelivery
}

/// Parses MTA Bus Time SIRI StopMonitoring JSON (version 2).
/// ExpectedArrivalTime is preferred, then ExpectedDepartureTime, then AimedArrivalTime.
public enum SIRIParser {
    public static func parse(json data: Data, monitoredStopID: String, now: Date) throws -> [Arrival] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any] else { throw SIRIError.malformed }
        guard let siri = object["Siri"] as? [String: Any] else { throw SIRIError.malformed }
        guard let delivery = siri["ServiceDelivery"] as? [String: Any] else { throw SIRIError.noDelivery }
        let containers = array(delivery["StopMonitoringDelivery"])
        if containers.isEmpty { return [] }

        let earliest = now.timeIntervalSince1970 - 30
        let latest = now.timeIntervalSince1970 + 3 * 3600
        var arrivals: [Arrival] = []
        for container in containers {
            guard let container = container as? [String: Any] else { continue }
            for visit in array(container["MonitoredStopVisit"]) {
                guard let visit = visit as? [String: Any],
                      let journey = visit["MonitoredVehicleJourney"] as? [String: Any]
                else { continue }
                let published = string(journey["PublishedLineName"])
                let lineRef = string(journey["LineRef"]) ?? ""
                let routeID = routeIdentifier(published: published, lineRef: lineRef)
                guard !routeID.isEmpty else { continue }
                let destination = string(journey["DestinationName"])
                let call = journey["MonitoredCall"] as? [String: Any]
                guard let epoch = eventEpoch(call) else { continue }
                if epoch < earliest || epoch > latest { continue }
                arrivals.append(
                    Arrival(
                        routeID: routeID,
                        stopID: monitoredStopID,
                        epoch: epoch,
                        destination: destination,
                        isSample: false
                    )
                )
            }
        }
        return arrivals.sorted { $0.epoch < $1.epoch }
    }

    static func routeIdentifier(published: String?, lineRef: String) -> String {
        if let published, !published.isEmpty { return published }
        guard let separator = lineRef.lastIndex(of: "_") else { return lineRef }
        let suffix = lineRef[lineRef.index(after: separator)...]
        return suffix.isEmpty ? lineRef : String(suffix)
    }

    private static func eventEpoch(_ call: [String: Any]?) -> TimeInterval? {
        guard let call else { return nil }
        let keys = ["ExpectedArrivalTime", "ExpectedDepartureTime", "AimedArrivalTime", "AimedDepartureTime"]
        for key in keys {
            if let raw = string(call[key]), let date = parseDate(raw) {
                return date.timeIntervalSince1970
            }
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func array(_ value: Any?) -> [Any] {
        if let list = value as? [Any] { return list }
        if let one = value as? [String: Any] { return [one] }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let list = value as? [Any] {
            for item in list {
                if let text = string(item) { return text }
            }
        }
        return nil
    }
}
