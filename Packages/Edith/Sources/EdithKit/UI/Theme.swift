import SwiftUI

public let brandAccent = Color(.sRGB, red: 217 / 255, green: 119 / 255, blue: 87 / 255)

public let usageSage = Color(.sRGB, red: 106 / 255, green: 141 / 255, blue: 115 / 255)

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case accent, blue, indigo, teal, green, purple, pink, red, orange

    public var id: String { rawValue }

    public init(storedName: String) {
        self = AppTheme(rawValue: storedName) ?? .accent
    }

    public var color: Color {
        switch self {
        case .accent: brandAccent
        case .blue: .blue
        case .indigo: .indigo
        case .teal: .teal
        case .green: .green
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        }
    }
}

public let themePalette: [(name: String, color: Color)] = AppTheme.allCases.dropFirst().map {
    ($0.rawValue, $0.color)
}

public func themeColor(_ name: String) -> Color {
    AppTheme(storedName: name).color
}
