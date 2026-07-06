import SwiftUI

public let themePalette: [(name: String, color: Color)] = [
    ("blue", .blue), ("indigo", .indigo), ("teal", .teal), ("green", .green),
    ("purple", .purple), ("pink", .pink), ("red", .red), ("orange", .orange),
]

public func themeColor(_ name: String) -> Color {
    if name == "accent" { return .accentColor }
    return themePalette.first { $0.name == name }?.color ?? .accentColor
}
