import SwiftUI

public enum UIScale {
    nonisolated(unsafe) public private(set) static var current: Double = 1

    @MainActor
    public static func apply(_ value: Double) {
        current = WindowZoom.clamp(value)
    }

    public static func pt(_ value: Double) -> Double {
        value * current
    }

    public static var controlSize: ControlSize {
        switch current {
        case ..<1.15: return .regular
        case ..<1.45: return .large
        default: return .extraLarge
        }
    }
}
