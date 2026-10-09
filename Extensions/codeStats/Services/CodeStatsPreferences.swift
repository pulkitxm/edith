import EdithExtensionSupport
import Foundation

public enum CodeStatsScheduleKind: String, CaseIterable, Codable, Sendable {
    case manual
    case daily
    case weekly

    public init(_ schedule: CodeStatsSchedule) {
        switch schedule {
        case .manual: self = .manual
        case .daily: self = .daily
        case .weekly: self = .weekly
        }
    }
}

public enum CodeStatsFolderError: LocalizedError, Equatable {
    case emptyPath
    case missing(String)
    case notDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPath: "the code stats folder path cannot be blank"
        case .missing(let path): "no folder exists at \(path)"
        case .notDirectory(let path): "\(path) is not a folder"
        }
    }
}

public struct CodeStatsFolderSelection: Equatable, Sendable {
    public let path: String
    public let changed: Bool
    public let external: Bool
}

public enum CodeStatsPreferences {
    public static let defaultHour = 9
    public static let defaultWeekday = 2
    public static let hours = 0...23
    public static let weekdays = 1...7

    private typealias Keys = AppStorageKeys.CodeStats

    public static func load(
        from defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodeStatsSettings {
        CodeStatsSettings(
            folder: CodeStatsPaths.selectedFolder(defaults: defaults, homeDirectory: homeDirectory),
            identity: identity(in: defaults),
            includeForks: defaults.bool(forKey: Keys.includeForks),
            includeArchived: defaults.object(forKey: Keys.includeArchived) as? Bool ?? true,
            schedule: schedule(in: defaults))
    }

    public static func schedule(in defaults: UserDefaults) -> CodeStatsSchedule {
        let hour = defaults.object(forKey: Keys.scheduleHour) as? Int ?? defaultHour
        let weekday = defaults.object(forKey: Keys.scheduleWeekday) as? Int ?? defaultWeekday
        switch CodeStatsScheduleKind(rawValue: defaults.string(forKey: Keys.scheduleKind) ?? "") {
        case .daily: return .daily(hour: hour)
        case .weekly: return .weekly(weekday: weekday, hour: hour)
        case .manual, nil: return .manual
        }
    }

    public static func setSchedule(_ schedule: CodeStatsSchedule, in defaults: UserDefaults) {
        defaults.set(CodeStatsScheduleKind(schedule).rawValue, forKey: Keys.scheduleKind)
        switch schedule {
        case .manual:
            break
        case .daily(let hour):
            defaults.set(hour, forKey: Keys.scheduleHour)
        case .weekly(let weekday, let hour):
            defaults.set(hour, forKey: Keys.scheduleHour)
            defaults.set(weekday, forKey: Keys.scheduleWeekday)
        }
    }

    public static func identity(in defaults: UserDefaults) -> CodeStatsIdentity {
        CodeStatsIdentity(
            substrings: defaults.stringArray(forKey: Keys.identitySubstrings) ?? [],
            emails: defaults.stringArray(forKey: Keys.identityEmails) ?? [])
    }

    public static func setIdentity(_ identity: CodeStatsIdentity, in defaults: UserDefaults) {
        defaults.set(identity.substrings, forKey: Keys.identitySubstrings)
        defaults.set(identity.emails, forKey: Keys.identityEmails)
    }

    @discardableResult
    public static func addIdentity(_ raw: String, in defaults: UserDefaults) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        var identity = identity(in: defaults)
        let lowered = value.lowercased()
        if value.contains("@") {
            guard !identity.emails.contains(where: { $0.lowercased() == lowered }) else {
                return false
            }
            identity.emails.append(value)
        } else {
            guard !identity.substrings.contains(where: { $0.lowercased() == lowered }) else {
                return false
            }
            identity.substrings.append(value)
        }
        setIdentity(identity, in: defaults)
        return true
    }

    @discardableResult
    public static func removeIdentity(_ raw: String, in defaults: UserDefaults) -> Bool {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identity = identity(in: defaults)
        let kept = CodeStatsIdentity(
            substrings: identity.substrings.filter { $0.lowercased() != lowered },
            emails: identity.emails.filter { $0.lowercased() != lowered })
        guard kept != identity else { return false }
        setIdentity(kept, in: defaults)
        return true
    }

    public static func selectFolder(
        _ rawPath: String, defaults: UserDefaults = SharedDefaults.store,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> CodeStatsFolderSelection {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw CodeStatsFolderError.emptyPath }
        let url = CodeStatsPaths.standardizedURL(
            path, homeDirectory: homeDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CodeStatsFolderError.missing(url.path)
        }
        guard isDirectory.boolValue else { throw CodeStatsFolderError.notDirectory(url.path) }
        let previous = CodeStatsPaths.selectedFolder(
            defaults: defaults, homeDirectory: homeDirectory)
        CodeStatsPaths.setFolder(url.path, defaults: defaults, homeDirectory: homeDirectory)
        return CodeStatsFolderSelection(
            path: url.path, changed: previous != url.path,
            external: RestoredPathValidation.verdict(
                for: url.path, homeDirectory: homeDirectory) == .drop)
    }
}
