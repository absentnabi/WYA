import Foundation

public enum FixtureArrivals {
    /// Stable sample countdowns so the UI is usable before API keys are set.
    public static func make(stopID: String, routeIDs: [String], now: Date) -> [Arrival] {
        var arrivals: [Arrival] = []
        for (offset, route) in routeIDs.prefix(5).enumerated() {
            let seed = hash(stopID + "|" + route)
            for step in 0..<3 {
                let minutes = 2 + ((seed + step * 5 + offset * 3) % 16)
                arrivals.append(
                    Arrival(
                        routeID: route,
                        stopID: stopID,
                        epoch: now.timeIntervalSince1970 + Double(minutes * 60),
                        destination: nil,
                        isSample: true
                    )
                )
            }
        }
        return arrivals.sorted { $0.epoch < $1.epoch }
    }

    private static func hash(_ text: String) -> Int {
        var value: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            value ^= UInt32(byte)
            value &*= 16_777_619
        }
        return Int(value % 997)
    }
}
