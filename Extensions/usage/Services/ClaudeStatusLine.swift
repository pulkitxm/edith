import EdithExtensionSupport
import Foundation

public enum ClaudeStatusLine {
    public struct Limits: Equatable, Sendable {
        public let session: LimitWindow?
        public let week: LimitWindow?

        public init(session: LimitWindow?, week: LimitWindow?) {
            self.session = session
            self.week = week
        }
    }

    public enum Change: String, Equatable, Sendable {
        case installed
        case wrapped
        case unchanged
        case removed
        case restored
        case absent
    }

    public enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case missingExecutable

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                "\(path) is not a JSON object, so Edith left it untouched"
            case .missingExecutable:
                "Edith could not find its application executable"
            }
        }
    }

    public static let setupHint =
        "Connect Claude Code’s status line in Usage settings to collect its limits"

    static let recordInvocation = "extension command usage usage.statusline.record"
    static let thenFlag = " --then "

    public static func settingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = UsageExecutionEnvironment.home
    ) -> URL {
        if let fixture = UsageExecutionEnvironment.fixtureHome(environment: environment) {
            return fixture.appendingPathComponent(".claude/settings.json")
        }
        let configured = environment["CLAUDE_CONFIG_DIR"].flatMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            return URL(
                fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let directory = configured ?? home.appendingPathComponent(".claude", isDirectory: true)
        return directory.appendingPathComponent("settings.json")
    }

    public static func limits(from data: Data) -> Limits? {
        guard data.count <= 1_024 * 1_024,
            let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rateLimits = input["rate_limits"] as? [String: Any]
        else { return nil }
        let limits = Limits(
            session: window(rateLimits["five_hour"]), week: window(rateLimits["seven_day"]))
        return limits.session == nil && limits.week == nil ? nil : limits
    }

    @discardableResult
    public static func record(
        _ data: Data, now: Date = Date(), history: URL = LimitsHistory.url
    ) -> Limits? {
        guard let limits = limits(from: data) else { return nil }
        var store = LimitsHistory(url: history)
        let latest = LimitsHistory.latest(provider: .claude, url: history)
        store.append(
            provider: .claude, session: limits.session, week: limits.week,
            fable: current(latest?.fable, now: now), now: now)
        return limits
    }

    public static func line(for limits: Limits) -> String {
        [("5h", limits.session), ("7d", limits.week)].compactMap { label, window in
            window.map { "\(label) \(Int($0.percent.rounded()))%" }
        }.joined(separator: " · ")
    }

    public static func snapshot(
        now: Date = Date(), settings: URL = settingsURL(), history: URL = LimitsHistory.url
    ) -> LimitsProviderSnapshot {
        guard isInstalled(settings: settings) else {
            return LimitsProviderSnapshot(
                provider: .claude, session: nil, week: nil, error: setupHint)
        }
        let latest = LimitsHistory.latest(provider: .claude, url: history)
        return LimitsProviderSnapshot(
            provider: .claude, session: current(latest?.session, now: now),
            week: current(latest?.week, now: now), fable: current(latest?.fable, now: now))
    }

    public static func command(executable: String, wrapping previous: String?) -> String {
        let recorder = "\(shellQuoted(executable)) \(recordInvocation)"
        guard let previous else { return recorder }
        return recorder + thenFlag + shellQuoted(previous)
    }

    public static func isRecorder(_ command: String) -> Bool {
        command.contains(" \(recordInvocation)")
    }

    public static func wrappedCommand(in command: String) -> String? {
        guard isRecorder(command),
            let marker = command.range(of: recordInvocation + thenFlag)
        else { return nil }
        return shellUnquoted(String(command[marker.upperBound...]))
    }

    public static func isInstalled(settings url: URL = settingsURL()) -> Bool {
        installedCommand(settings: url) != nil
    }

    public static func installedCommand(settings url: URL = settingsURL()) -> String? {
        guard let document = try? readSettings(url), let command = statusCommand(in: document),
            isRecorder(command)
        else { return nil }
        return command
    }

    @discardableResult
    public static func install(executable: String, settings url: URL = settingsURL()) throws
        -> Change
    {
        var document = try readSettings(url) ?? [:]
        let existing = statusCommand(in: document)
        let previous = existing.flatMap { isRecorder($0) ? wrappedCommand(in: $0) : $0 }
        let command = command(executable: executable, wrapping: previous)
        guard existing != command else { return .unchanged }
        var statusLine = document["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = command
        document["statusLine"] = statusLine
        try writeSettings(document, to: url)
        return previous == nil ? .installed : .wrapped
    }

    public static func defaultExecutable(
        bundle: Bundle = .main, fileManager: FileManager = .default
    ) -> String? {
        bundle.executableURL.flatMap { launcher(beside: $0, fileManager: fileManager) }
    }

    static func launcher(beside executable: URL, fileManager: FileManager = .default) -> String? {
        let launcher = executable.standardizedFileURL
        return fileManager.isExecutableFile(atPath: launcher.path) ? launcher.path : nil
    }

    public static func isOptedOut(defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.bool(forKey: AppStorageKeys.Limits.claudeStatusLineOptOut)
    }

    @discardableResult
    public static func connect(
        executable: String, settings url: URL = settingsURL(),
        defaults: UserDefaults = SharedDefaults.store
    ) throws -> Change {
        defaults.removeObject(forKey: AppStorageKeys.Limits.claudeStatusLineOptOut)
        return try install(executable: executable, settings: url)
    }

    @discardableResult
    public static func disconnect(
        settings url: URL = settingsURL(), defaults: UserDefaults = SharedDefaults.store
    ) throws -> Change {
        defaults.set(true, forKey: AppStorageKeys.Limits.claudeStatusLineOptOut)
        return try remove(settings: url)
    }

    @discardableResult
    public static func setConnected(
        _ connected: Bool, settings url: URL = settingsURL()
    ) async throws -> Change {
        guard connected else { return try disconnect(settings: url) }
        guard let executable = defaultExecutable() else { throw Failure.missingExecutable }
        return try connect(executable: executable, settings: url)
    }

    public static func isConnected(settings url: URL = settingsURL()) async -> Bool {
        isInstalled(settings: url)
    }

    @discardableResult
    public static func remove(settings url: URL = settingsURL()) throws -> Change {
        guard var document = try readSettings(url),
            var statusLine = document["statusLine"] as? [String: Any],
            let command = statusLine["command"] as? String, isRecorder(command)
        else { return .absent }
        if let previous = wrappedCommand(in: command) {
            statusLine["command"] = previous
            document["statusLine"] = statusLine
            try writeSettings(document, to: url)
            return .restored
        }
        document.removeValue(forKey: "statusLine")
        try writeSettings(document, to: url)
        return .removed
    }

    private static func window(_ value: Any?) -> LimitWindow? {
        guard let window = value as? [String: Any],
            let percent = (window["used_percentage"] as? NSNumber)?.doubleValue,
            percent.isFinite, (0...1_000_000).contains(percent)
        else { return nil }
        let resetsAt = (window["resets_at"] as? NSNumber).flatMap { value -> Date? in
            let seconds = value.doubleValue
            guard seconds.isFinite, (-62_135_596_800...253_402_300_799).contains(seconds) else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        }
        return LimitWindow(percent: percent, resetsAt: resetsAt)
    }

    private static func current(_ window: LimitWindow?, now: Date) -> LimitWindow? {
        guard let window else { return nil }
        if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
        return window
    }

    private static func statusCommand(in document: [String: Any]) -> String? {
        (document["statusLine"] as? [String: Any])?["command"] as? String
    }

    private static func readSettings(_ url: URL) throws -> [String: Any]? {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard
            let data = try? UsageDataFiles.readRegularFile(at: target, maximumBytes: 1_024 * 1_024),
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.unreadable(url.path) }
        return document
    }

    private static func writeSettings(_ document: [String: Any], to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let permissions =
            (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: target, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func shellUnquoted(_ value: String) -> String? {
        guard value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") else { return nil }
        return String(value.dropFirst().dropLast()).replacingOccurrences(
            of: #"'\''"#, with: "'")
    }
}
