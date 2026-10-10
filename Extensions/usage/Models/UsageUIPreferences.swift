import EdithExtensionSupport
import Foundation

struct UsageUIPreferences: Codable, Equatable, Sendable {
    enum Value: Codable, Equatable, Sendable {
        case bool(Bool)
        case number(Double)
        case text(String)
        case strings([String])

        var object: Any {
            switch self {
            case .bool(let value): value
            case .number(let value): value
            case .text(let value): value
            case .strings(let value): value
            }
        }
    }

    var values: [String: Value]
    static let editableKeys: Set<String> = [
        AppStorageKeys.Budget.capPercent,
        AppStorageKeys.Budget.deadline,
        AppStorageKeys.Budget.enabled,
        AppStorageKeys.Budget.kind,
        AppStorageKeys.Budget.mode,
        AppStorageKeys.General.smartColor,
        AppStorageKeys.Limits.claudeEnabled,
        AppStorageKeys.Limits.codexEnabled,
        AppStorageKeys.Limits.critPercent,
        AppStorageKeys.Limits.cursorEnabled,
        AppStorageKeys.Limits.grokEnabled,
        AppStorageKeys.Limits.inMenuBar,
        AppStorageKeys.Limits.pacingMargin,
        AppStorageKeys.Limits.provider,
        AppStorageKeys.Limits.warnPercent,
        AppStorageKeys.MenuBar.claudeWindows,
        AppStorageKeys.MenuBar.codexWindows,
        AppStorageKeys.MenuBar.colorMode,
        AppStorageKeys.MenuBar.cursorWindows,
        AppStorageKeys.MenuBar.grokWindows,
        AppStorageKeys.MenuBar.highColorHex,
        AppStorageKeys.MenuBar.limitsStyle,
        AppStorageKeys.MenuBar.lowColorHex,
        AppStorageKeys.MenuBar.midColorHex,
        AppStorageKeys.MenuBar.subColorHex,
        AppStorageKeys.Notify.almostCapped,
        AppStorageKeys.Notify.almostCappedPercent,
        AppStorageKeys.Notify.back,
        AppStorageKeys.Notify.capped,
        AppStorageKeys.Notify.headroom,
        AppStorageKeys.Notify.loginProblems,
        AppStorageKeys.Notify.master,
        AppStorageKeys.Notify.onPace,
        AppStorageKeys.Notify.outlook,
        AppStorageKeys.Notify.trackSession,
        AppStorageKeys.Notify.trackWeekly,
        "dashRange", "dashSources", "dashKnownSources", "dashSourceSelectionVersion",
        "dashModels", "dashPaths", "dashSort", "dashSortAsc", "projSort", "projSortAsc",
        "dashHeatMetric",
    ]
    static let displayKeys: Set<String> = [
        AppStorageKeys.General.theme, AppStorageKeys.General.appearance,
        AppStorageKeys.Presenter.blurMoney, AppStorageKeys.Presenter.blurUsage,
    ]

    static func read(_ defaults: UserDefaults) -> Self {
        var values: [String: Value] = [:]
        for key in editableKeys.union(displayKeys) {
            switch defaults.object(forKey: key) {
            case let value as String: values[key] = .text(value)
            case let value as [String]: values[key] = .strings(value)
            case let value as NSNumber:
                values[key] =
                    CFGetTypeID(value) == CFBooleanGetTypeID()
                    ? .bool(value.boolValue) : .number(value.doubleValue)
            default: break
            }
        }
        return Self(values: values)
    }

    func validate() throws {
        guard Set(values.keys).isSubset(of: Self.editableKeys), values.count <= 100 else {
            throw ExtensionPeerError.invalidRequest
        }
        for (key, value) in values {
            let numeric: Set<String> = [
                AppStorageKeys.Budget.capPercent, AppStorageKeys.Budget.deadline,
                AppStorageKeys.Limits.critPercent, AppStorageKeys.Limits.pacingMargin,
                AppStorageKeys.Limits.warnPercent,
                AppStorageKeys.Notify.almostCappedPercent, "dashSourceSelectionVersion",
            ]
            let flags: Set<String> = [
                AppStorageKeys.Budget.enabled, AppStorageKeys.General.smartColor,
                AppStorageKeys.Limits.claudeEnabled, AppStorageKeys.Limits.codexEnabled,
                AppStorageKeys.Limits.cursorEnabled,
                AppStorageKeys.Limits.grokEnabled, AppStorageKeys.Limits.inMenuBar,
                AppStorageKeys.Notify.almostCapped,
                AppStorageKeys.Notify.back, AppStorageKeys.Notify.capped,
                AppStorageKeys.Notify.headroom,
                AppStorageKeys.Notify.loginProblems, AppStorageKeys.Notify.master,
                AppStorageKeys.Notify.onPace,
                AppStorageKeys.Notify.outlook, AppStorageKeys.Notify.trackSession,
                AppStorageKeys.Notify.trackWeekly,
                "dashSortAsc", "projSortAsc",
            ]
            switch value {
            case .bool: guard flags.contains(key) else { throw ExtensionPeerError.invalidRequest }
            case .number:
                guard numeric.contains(key) else { throw ExtensionPeerError.invalidRequest }
            case .text:
                guard !flags.contains(key), !numeric.contains(key) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case .strings: throw ExtensionPeerError.invalidRequest
            }
            switch value {
            case .bool: break
            case .number(let number):
                guard number.isFinite, abs(number) <= 1_000_000_000_000 else {
                    throw ExtensionPeerError.invalidRequest
                }
            case .text(let text):
                guard text.utf8.count <= 65_536, !text.utf8.contains(0) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case .strings(let strings):
                guard strings.count <= 100,
                    strings.allSatisfy({
                        $0.utf8.count <= 4_096 && !$0.utf8.contains(0)
                    })
                else { throw ExtensionPeerError.invalidRequest }
            }
        }
    }

    func apply(to defaults: UserDefaults, replacing: Bool = false) {
        if replacing {
            for key in Self.editableKeys.union(Self.displayKeys) where values[key] == nil {
                defaults.removeObject(forKey: key)
            }
        }
        for (key, value) in values {
            if !NSDictionary(dictionary: ["value": defaults.object(forKey: key) ?? NSNull()])
                .isEqual(to: ["value": value.object])
            {
                defaults.set(value.object, forKey: key)
            }
        }
    }
}
