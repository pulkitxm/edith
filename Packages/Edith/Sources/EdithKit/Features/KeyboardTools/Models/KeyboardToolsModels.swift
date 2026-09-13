import CoreGraphics
import Foundation

public enum KeyboardSuperTapAction: String, CaseIterable, Identifiable, Sendable {
    case none
    case escape
    case openEdith

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Do nothing"
        case .escape: "Escape"
        case .openEdith: "Open Edith"
        }
    }
}

public enum KeyboardSuperHoldAction: String, CaseIterable, Identifiable, Sendable {
    case hyper
    case commandOption
    case controlOption
    case controlCommand

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hyper: "Control + Option + Shift + Command"
        case .commandOption: "Command + Option"
        case .controlOption: "Control + Option"
        case .controlCommand: "Control + Command"
        }
    }

    public var eventFlags: CGEventFlags {
        switch self {
        case .hyper: [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        case .commandOption: [.maskCommand, .maskAlternate]
        case .controlOption: [.maskControl, .maskAlternate]
        case .controlCommand: [.maskControl, .maskCommand]
        }
    }
}

public struct KeyboardToolsSettings: Equatable, Sendable {
    public static let debounceRange = 10...500
    public static let defaultDebounceWindow = 50

    public let debounceEnabled: Bool
    public let debounceWindow: Int
    public let superEnabled: Bool
    public let superTapAction: KeyboardSuperTapAction
    public let superHoldAction: KeyboardSuperHoldAction

    public init(
        debounceEnabled: Bool, debounceWindow: Int, superEnabled: Bool,
        superTapAction: KeyboardSuperTapAction, superHoldAction: KeyboardSuperHoldAction
    ) {
        self.debounceEnabled = debounceEnabled
        self.debounceWindow = Self.sanitizedDebounceWindow(debounceWindow)
        self.superEnabled = superEnabled
        self.superTapAction = superTapAction
        self.superHoldAction = superHoldAction
    }

    public static func load(_ defaults: UserDefaults = SharedDefaults.store) -> Self {
        let storedWindow =
            defaults.object(forKey: AppStorageKeys.KeyboardTools.debounceWindow)
            as? Int ?? defaultDebounceWindow
        return KeyboardToolsSettings(
            debounceEnabled: defaults.object(
                forKey: AppStorageKeys.KeyboardTools.debounceEnabled) as? Bool ?? true,
            debounceWindow: storedWindow,
            superEnabled: defaults.object(
                forKey: AppStorageKeys.KeyboardTools.superEnabled) as? Bool ?? true,
            superTapAction: KeyboardSuperTapAction(
                rawValue: defaults.string(
                    forKey: AppStorageKeys.KeyboardTools.superTapAction) ?? "") ?? .escape,
            superHoldAction: KeyboardSuperHoldAction(
                rawValue: defaults.string(
                    forKey: AppStorageKeys.KeyboardTools.superHoldAction) ?? "") ?? .hyper)
    }

    public static func sanitizedDebounceWindow(_ value: Int) -> Int {
        min(debounceRange.upperBound, max(debounceRange.lowerBound, value))
    }
}

public struct KeyboardDebounceState {
    public enum EventKind {
        case down
        case up
    }

    private struct KeyState {
        var down = false
        var suppressedPresses = 0
        var lastPress: UInt64?
        var lastRelease: UInt64?
        var lastEvent: UInt64?
    }

    private static let staleGap: UInt64 = 5_000_000_000
    private var keys: [Int64: KeyState] = [:]
    private var lastAcceptedKey: Int64?

    public init() {}

    public mutating func reset() {
        keys.removeAll()
        lastAcceptedKey = nil
    }

    public mutating func shouldSuppress(
        keyCode: Int64, repeatEvent: Bool, kind: EventKind, timestamp: UInt64,
        settings: KeyboardToolsSettings
    ) -> Bool {
        guard settings.debounceEnabled else {
            keys.removeValue(forKey: keyCode)
            return false
        }
        var key = sanitizedKey(keyCode, timestamp: timestamp)
        guard kind == .down else {
            if key.suppressedPresses > 0 {
                key.suppressedPresses -= 1
                key.lastEvent = timestamp
                keys[keyCode] = key
                return true
            }
            if key.down {
                key.down = false
                key.lastRelease = timestamp
            }
            key.lastEvent = timestamp
            keys[keyCode] = key
            return false
        }
        guard !repeatEvent else {
            key.down = true
            key.lastEvent = timestamp
            keys[keyCode] = key
            return false
        }
        let window = UInt64(settings.debounceWindow) * 1_000_000
        if key.down, let press = key.lastPress, timestamp >= press, timestamp - press < window {
            key.suppressedPresses += 1
            key.lastEvent = timestamp
            keys[keyCode] = key
            return true
        }
        if let release = key.lastRelease, lastAcceptedKey == keyCode, timestamp >= release,
            timestamp - release < window
        {
            key.suppressedPresses += 1
            key.lastEvent = timestamp
            keys[keyCode] = key
            return true
        }
        key.down = true
        key.lastPress = timestamp
        key.lastEvent = timestamp
        keys[keyCode] = key
        lastAcceptedKey = keyCode
        return false
    }

    private mutating func sanitizedKey(_ code: Int64, timestamp: UInt64) -> KeyState {
        var key = keys[code] ?? KeyState()
        if let previous = key.lastEvent,
            timestamp < previous || timestamp - previous > Self.staleGap
        {
            key = KeyState()
            if lastAcceptedKey == code { lastAcceptedKey = nil }
        }
        return key
    }
}

public struct KeyboardSuperState {
    public enum Decision: Equatable {
        case pass
        case swallow
        case addModifiers
        case tap
    }

    public static let triggerKeyCode: Int64 = 79
    public static let triggerUsage: UInt64 = 0x70000006D
    public static let capsLockUsage: UInt64 = 0x700000039
    public static let tapMaximum: UInt64 = 500_000_000
    public static let staleHold: UInt64 = 5_000_000_000

    public private(set) var held = false
    private var used = false
    private var pressedAt: UInt64?

    public init() {}

    public mutating func reset() {
        held = false
        used = false
        pressedAt = nil
    }

    public mutating func decide(
        type: CGEventType, keyCode: Int64, repeatEvent: Bool, timestamp: UInt64
    ) -> Decision {
        expire(at: timestamp)
        if keyCode == Self.triggerKeyCode {
            if type == .keyDown {
                if !repeatEvent, !held {
                    held = true
                    used = false
                    pressedAt = timestamp
                }
                return .swallow
            }
            if type == .keyUp {
                let shouldTap =
                    held && !used
                    && pressedAt.map {
                        timestamp >= $0 && timestamp - $0 <= Self.tapMaximum
                    } == true
                reset()
                return shouldTap ? .tap : .swallow
            }
        }
        guard held else { return .pass }
        if type == .keyDown || type == .keyUp {
            used = true
            return .addModifiers
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            used = true
            return .addModifiers
        }
        if type == .flagsChanged {
            used = true
        }
        return .pass
    }

    private mutating func expire(at timestamp: UInt64) {
        guard let pressedAt,
            timestamp < pressedAt || timestamp - pressedAt > Self.staleHold
        else { return }
        reset()
    }
}
