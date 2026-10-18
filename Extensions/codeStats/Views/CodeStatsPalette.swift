import Foundation
import SwiftUI

enum DashPalette {
    static let lightCat = [
        "#d97757", "#2f4858", "#c89b3c", "#6a8d73", "#8c5e58",
        "#4a6b8a", "#b07156", "#7d6b9e", "#9aa05c", "#5f7a7a",
    ]
    static let darkCat = [
        "#e08a6a", "#7ea7be", "#d8b04f", "#85ab8e", "#b07d74",
        "#6f97bd", "#c98a6c", "#9c8bc0", "#b3bb6e", "#7fa0a0",
    ]
    static let other = "#b8b0a4"

    static let lightColors = lightCat.map(color)
    static let darkColors = darkCat.map(color)
    static let otherColor = color(other)
    static let slateLight = color("#2f4858")
    static let slateDark = color("#7ea7be")

    static func cat(_ dark: Bool) -> [String] { dark ? darkCat : lightCat }
    static func slate(_ dark: Bool) -> Color { dark ? slateDark : slateLight }

    static func categorical(_ index: Int, dark: Bool) -> Color {
        let c = dark ? darkColors : lightColors
        return c[((index % c.count) + c.count) % c.count]
    }

    static func modelColor(_ index: Int?, dark: Bool) -> Color {
        guard let index else { return otherColor }
        return categorical(index, dark: dark)
    }

    static func sourceColor(_ index: Int?, dark: Bool) -> Color {
        guard let index else { return otherColor }
        return index == 0 ? slate(dark) : categorical(index - 1, dark: dark)
    }

    static let inputColor = { (dark: Bool) in slate(dark) }
    static func outputColor(_ dark: Bool) -> Color { categorical(0, dark: dark) }
    static let cacheCreateColor = color("#c89b3c")
    static let cacheReadColor = color("#6a8d73")

    static func color(_ hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >> 8) & 0xff) / 255
        let b = Double(value & 0xff) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
