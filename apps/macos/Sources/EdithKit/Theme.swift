import SwiftUI

public let themePalette: [(name: String, color: Color)] = [
    ("blue", .blue), ("indigo", .indigo), ("teal", .teal), ("green", .green),
    ("purple", .purple), ("pink", .pink), ("red", .red), ("orange", .orange),
]

public let brandAccent = Color(.sRGB, red: 217 / 255, green: 119 / 255, blue: 87 / 255)

public func themeColor(_ name: String) -> Color {
    if name == "accent" { return brandAccent }
    return themePalette.first { $0.name == name }?.color ?? brandAccent
}
