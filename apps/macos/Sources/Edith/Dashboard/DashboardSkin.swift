import SwiftUI

enum DashSkin {
    static func paper(_ d: Bool) -> Color { DashPalette.color(d ? "#1a1714" : "#f7f3ec") }
    static func paper2(_ d: Bool) -> Color { DashPalette.color(d ? "#221d19" : "#fffdf8") }
    static func ink(_ d: Bool) -> Color { DashPalette.color(d ? "#f1e9dc" : "#241f1a") }
    static func inkSoft(_ d: Bool) -> Color { DashPalette.color(d ? "#bcae9c" : "#5c5247") }
    static func inkFaint(_ d: Bool) -> Color { DashPalette.color(d ? "#8a7d6c" : "#8a7f72") }
    static func line(_ d: Bool) -> Color { DashPalette.color(d ? "#332e27" : "#e4dccf") }
    static func lineStrong(_ d: Bool) -> Color { DashPalette.color(d ? "#423b32" : "#d6cbb8") }
    static func accent(_ d: Bool) -> Color { DashPalette.color(d ? "#e08a6a" : "#d97757") }
    static func accentDeep(_ d: Bool) -> Color { DashPalette.color(d ? "#eea486" : "#b3543a") }
    static func grid(_ d: Bool) -> Color { DashPalette.color(d ? "#2b2620" : "#ece5d8") }
    static let gold = DashPalette.color("#c89b3c")
    static let sage = DashPalette.color("#6a8d73")

    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Iowan Old Style", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct SkinCard<Content: View>: View {
    let title: String
    var note: String? = nil
    let dark: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(DashSkin.serif(18))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                if let note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .multilineTextAlignment(.trailing)
                }
            }
            content()
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).strokeBorder(DashSkin.line(dark), lineWidth: 1)
        )
        .shadow(color: .black.opacity(dark ? 0.32 : 0.05), radius: 12, y: 8)
    }
}
