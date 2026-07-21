import AppKit

public enum WindowKeyCommand: Equatable, Sendable {
    case zoomIn
    case zoomOut
    case zoomReset
    case select(Int)
    case selectLast
    case cycleForward
    case cycleBackward

    public static let tabKeyCode: UInt16 = 48
    public static let directSelectLimit = 8

    public static func resolve(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> WindowKeyCommand? {
        let active = modifiers.intersection([.command, .control, .option, .shift])
        if keyCode == tabKeyCode {
            guard active.subtracting(.shift) == .control else { return nil }
            return active.contains(.shift) ? .cycleBackward : .cycleForward
        }
        guard active.subtracting(.shift) == .command, let characters else { return nil }
        switch characters {
        case "=", "+": return .zoomIn
        case "-", "_": return .zoomOut
        case "0": return .zoomReset
        case "9": return .selectLast
        default:
            guard let digit = Int(characters), (1...directSelectLimit).contains(digit) else {
                return nil
            }
            return .select(digit - 1)
        }
    }

    public static func resolvedIndex(
        for command: WindowKeyCommand, count: Int, current: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        switch command {
        case .select(let index): return index < count ? index : nil
        case .selectLast: return count - 1
        case .cycleForward: return (current + 1) % count
        case .cycleBackward: return (current - 1 + count) % count
        default: return nil
        }
    }
}

public enum WindowZoom {
    public static let range = 0.8...1.6
    public static let step = 0.1
    public static let defaultsKey = "mainWindowZoom"

    public static func clamp(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (value * 100).rounded() / 100))
    }

    public static func adjusted(_ value: Double, for command: WindowKeyCommand) -> Double? {
        switch command {
        case .zoomIn: return clamp(value + step)
        case .zoomOut: return clamp(value - step)
        case .zoomReset: return 1
        default: return nil
        }
    }
}
