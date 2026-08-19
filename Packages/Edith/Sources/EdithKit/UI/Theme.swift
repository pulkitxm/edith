import SwiftUI

public let themePalette: [(name: String, color: Color)] = [
    ("terracotta", Color(red: 0.67, green: 0.29, blue: 0.20)),
    ("burntOrange", Color(red: 0.72, green: 0.38, blue: 0.18)),
    ("forest", Color(red: 0.18, green: 0.30, blue: 0.23)),
    ("sage", Color(red: 0.42, green: 0.52, blue: 0.42)),
    ("olive", Color(red: 0.48, green: 0.48, blue: 0.28)),
    ("brass", Color(red: 0.62, green: 0.49, blue: 0.25)),
    ("cream", Color(red: 0.86, green: 0.81, blue: 0.70)),
    ("charcoal", Color(red: 0.22, green: 0.21, blue: 0.19)),
]

public let brandAccent = Color(.sRGB, red: 217 / 255, green: 119 / 255, blue: 87 / 255)

public let usageSage = Color(.sRGB, red: 106 / 255, green: 141 / 255, blue: 115 / 255)

public func themeColor(_ name: String) -> Color {
    if name == "accent" { return brandAccent }
    return themePalette.first { $0.name == name }?.color ?? brandAccent
}
