import SwiftUI
import WYACore

enum Theme {
    static let accent = Color(red: 0.965, green: 0.737, blue: 0.149)
    static let walk = Color(red: 0.55, green: 0.62, blue: 0.70)
    static let wait = Color(red: 0.95, green: 0.58, blue: 0.20)

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.055, green: 0.063, blue: 0.082)
            : Color(red: 0.945, green: 0.952, blue: 0.962)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.110, green: 0.125, blue: 0.155)
            : Color.white
    }

    static func elevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.165, green: 0.180, blue: 0.215)
            : Color(red: 0.915, green: 0.925, blue: 0.940)
    }
}

extension Color {
    init(hex: String, fallback: Color = .gray) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt64(text, radix: 16) else {
            self = fallback
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum Format {
    static func distance(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet < 1000 {
            return "\(Int(feet.rounded())) ft"
        }
        return String(format: "%.1f mi", meters / 1609.344)
    }

    static func walk(_ meters: Double) -> String {
        let seconds = Int((meters * 1.25 / 1.30).rounded())
        if seconds < 45 { return "at the stop" }
        let minutes = max(1, DurationMath.roundedMinutes(seconds))
        return minutes == 1 ? "1 min walk" : "\(minutes) min walk"
    }

    static func legMinutes(_ seconds: Int) -> String {
        let minutes = DurationMath.roundedMinutes(seconds)
        if minutes <= 0 { return "<1m" }
        return "\(minutes)m"
    }
}
