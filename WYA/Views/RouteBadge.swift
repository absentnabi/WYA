import SwiftUI
import WYACore

struct RouteBadge: View {
    let name: String
    let colorHex: String
    let textHex: String

    init(route: TransitRoute) {
        name = route.shortName
        colorHex = route.color
        textHex = route.textColor
    }

    init(name: String, colorHex: String, textHex: String) {
        self.name = name
        self.colorHex = colorHex
        self.textHex = textHex
    }

    var body: some View {
        Text(name)
            .font(.system(size: name.count > 3 ? 11 : 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hex: textHex, fallback: .white))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, name.count > 2 ? 6 : 0)
            .frame(minWidth: 26, minHeight: 22)
            .background(Color(hex: colorHex), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel("\(name) route")
    }
}
