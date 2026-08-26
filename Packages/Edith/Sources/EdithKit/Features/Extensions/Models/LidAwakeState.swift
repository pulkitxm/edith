import Foundation

public enum LidAwakeState {
    public static let enabledKey = "lidAwakeEnabled"
    public static let activeKey = "lidAwakeActive"
    public static let restoreOnQuitKey = "lidAwakeRestoreOnQuit"
    public static let sessionKey = "lidAwakeSession"
    public static let sessionDeadlineKey = "lidAwakeSessionDeadline"
    public static let automaticStopPendingKey = "lidAwakeAutomaticStopPending"
    public static let batteryThresholdKey = "lidAwakeBatteryThreshold"
    public static let batteryThresholdRange = 0...100

    public static func isEnabled(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func isActive(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        isEnabled(defaults) && defaults.bool(forKey: activeKey)
    }

    public static func setActive(_ active: Bool, _ defaults: UserDefaults = SharedDefaults.store) {
        defaults.set(active, forKey: activeKey)
    }

    public static func restoresOnQuit(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.object(forKey: restoreOnQuitKey) as? Bool ?? true
    }

    public static func session(_ defaults: UserDefaults = SharedDefaults.store) -> LidAwakeSession {
        LidAwakeSession(rawValue: defaults.string(forKey: sessionKey) ?? "") ?? .indefinite
    }

    public static func setSession(
        _ session: LidAwakeSession, _ defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(session.rawValue, forKey: sessionKey)
    }

    public static func sessionDeadline(_ defaults: UserDefaults = SharedDefaults.store) -> Date? {
        guard let value = defaults.object(forKey: sessionDeadlineKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    public static func setSessionDeadline(
        _ deadline: Date?, _ defaults: UserDefaults = SharedDefaults.store
    ) {
        if let deadline {
            defaults.set(deadline.timeIntervalSince1970, forKey: sessionDeadlineKey)
        } else {
            defaults.removeObject(forKey: sessionDeadlineKey)
        }
    }

    public static func automaticStopPending(
        _ defaults: UserDefaults = SharedDefaults.store
    ) -> Bool {
        defaults.bool(forKey: automaticStopPendingKey)
    }

    public static func setAutomaticStopPending(
        _ pending: Bool, _ defaults: UserDefaults = SharedDefaults.store
    ) {
        if pending {
            defaults.set(true, forKey: automaticStopPendingKey)
        } else {
            defaults.removeObject(forKey: automaticStopPendingKey)
        }
    }

    public static func batteryThreshold(
        _ defaults: UserDefaults = SharedDefaults.store
    ) -> Int {
        normalizedBatteryThreshold(defaults.integer(forKey: batteryThresholdKey))
    }

    public static func normalizedBatteryThreshold(_ threshold: Int) -> Int {
        min(batteryThresholdRange.upperBound, max(batteryThresholdRange.lowerBound, threshold))
    }

    public static func isValidBatteryThreshold(_ threshold: Int) -> Bool {
        batteryThresholdRange.contains(threshold)
    }
}

public enum LidAwakeIPC {
    public enum Action: String, Sendable {
        case status
        case on
        case off
        case enableExtension
        case disableExtension
    }

    public static let actionKey = "action"
    public static let sessionKey = "session"
    public static let requestIDKey = "requestID"
    public static let deadlineKey = "deadline"
    public static let okKey = "ok"
    public static let errorKey = "error"
}

public enum LidAwakeSession: String, CaseIterable, Sendable {
    case indefinite
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case untilLidReopens

    public var minutes: Int? {
        switch self {
        case .indefinite, .untilLidReopens: nil
        case .fifteenMinutes: 15
        case .thirtyMinutes: 30
        case .oneHour: 60
        case .twoHours: 120
        }
    }

    public var title: String {
        switch self {
        case .indefinite: "Indefinitely"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilLidReopens: "Until lid reopens"
        }
    }
}

public enum LidAwakeBatteryAction: Equatable, Sendable {
    case none
    case suspend
    case resume
}

public enum LidAwakeBatteryPolicy {
    public static func decide(
        intent: Bool,
        suspended: Bool,
        overridden: Bool = false,
        percent: Int,
        onAC: Bool,
        threshold: Int,
        hysteresis: Int = 5
    ) -> LidAwakeBatteryAction {
        let threshold = LidAwakeState.normalizedBatteryThreshold(threshold)
        guard threshold > 0 else { return .none }
        if !suspended, intent, !onAC, !overridden, percent < threshold {
            return .suspend
        }
        let resumeThreshold = threshold + min(max(0, hysteresis), 100 - threshold)
        if suspended, onAC, percent >= resumeThreshold {
            return .resume
        }
        return .none
    }

    public static func shouldKeepOverride(_ overridden: Bool, onAC: Bool) -> Bool {
        overridden && !onAC
    }
}

public struct LidAwakeLidSessionTracker: Sendable {
    private enum State: Sendable {
        case inactive
        case waitingForClose
        case waitingForOpen
    }

    private var state = State.inactive

    public init() {}

    public var isActive: Bool {
        if case .inactive = state { return false }
        return true
    }

    public mutating func start(lidClosed: Bool?) {
        state = lidClosed == true ? .waitingForOpen : .waitingForClose
    }

    public mutating func cancel() {
        state = .inactive
    }

    public mutating func handle(lidClosed: Bool) -> Bool {
        switch (state, lidClosed) {
        case (.waitingForClose, true):
            state = .waitingForOpen
        case (.waitingForOpen, false):
            state = .inactive
            return true
        default:
            break
        }
        return false
    }
}

public enum LidAwakeOutcome: Equatable, Sendable {
    case applied
    case failed(String)
}

public enum LidAwakeCommand {
    public static let toolPath = "/usr/bin/pmset"

    public static func arguments(active: Bool) -> [String] {
        ["-a", "disablesleep", active ? "1" : "0"]
    }

    public static func shellCommand(active: Bool) -> String {
        ([toolPath] + arguments(active: active)).joined(separator: " ")
    }

    public static func sleepDisabled(inPowerSettings output: String) -> Bool {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            return fields[1] == "1"
        }
        return false
    }

}

@objc public protocol LidAwakePrivilegedProtocol {
    func setSleepDisabled(_ disable: Bool, reply: @escaping (NSError?) -> Void)
}
