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

    static let recordInvocation = "invoke usage usage.statusline.hook --json - --raw"
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
        let script = """
            input="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/edith-statusline.XXXXXX")" || exit 1
            trap '/bin/rm -f "$input"' EXIT
            /usr/bin/head -c 524289 >"$input"
            [ "$(/usr/bin/wc -c <"$input")" -le 524288 ] || exit 1
            \(recorder) <"$input" >/dev/null 2>/dev/null
            /bin/sh -c "$2" <"$input"
            """
        return "/bin/sh -c \(shellQuoted(script)) edith-statusline" + thenFlag
            + shellQuoted(previous)
    }

    public static func isRecorder(_ command: String) -> Bool {
        command.contains(" \(recordInvocation)")
    }

    public static func wrappedCommand(in command: String) -> String? {
        guard isRecorder(command),
            let marker = command.range(of: " edith-statusline" + thenFlag)
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
    public static func install(
        executable: String, settings url: URL = settingsURL(),
        ownedCommand: String? = nil,
        preserveOwnership: (String) throws -> Void = { _ in }
    ) throws
        -> Change
    {
        var document = try readSettings(url) ?? [:]
        let existing = statusCommand(in: document)
        let previous = existing.flatMap { existing in
            let wrapped = wrappedCommand(in: existing)
            let canonical = Self.command(executable: executable, wrapping: wrapped)
            return existing == ownedCommand || existing == canonical ? wrapped : existing
        }
        let installed = Self.command(executable: executable, wrapping: previous)
        try preserveOwnership(installed)
        guard existing != installed else { return .unchanged }
        var statusLine = document["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = installed
        document["statusLine"] = statusLine
        try writeSettings(document, to: url)
        return previous == nil ? .installed : .wrapped
    }

    private struct PublicLauncher: Decodable {
        let version: Int
        let hostIdentifier: String
        let applicationURL: URL
        let launcherURL: URL
        let buildVersion: String
        let signatureHash: Data
        let teamIdentifier: String?
        let bundleFileID: String
        let launcherFileID: String
        let launcherSHA256: String
    }

    static func publicExecutable(fromVerifiedContext context: NSDictionary) -> String? {
        let required: Set<String> = [
            "version", "hostIdentifier", "applicationURL", "launcherURL", "buildVersion",
            "signatureHash", "bundleFileID", "launcherFileID", "launcherSHA256",
        ]
        guard context["recoveryOnly"] as? Bool != true,
            let hostIdentifier = context["hostIdentifier"] as? String,
            let object = context["publicLauncher"] as? NSDictionary,
            Set(object.allKeys.compactMap { $0 as? String }).isSubset(
                of: required.union(["teamIdentifier"])),
            required.isSubset(of: Set(object.allKeys.compactMap { $0 as? String })),
            let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 32_768,
            let value = try? JSONDecoder().decode(PublicLauncher.self, from: data),
            value.version == 1, value.hostIdentifier == hostIdentifier,
            !hostIdentifier.isEmpty, hostIdentifier.utf8.count <= 200,
            hostIdentifier.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
            }),
            !value.buildVersion.isEmpty, value.buildVersion.utf8.count <= 80,
            !value.buildVersion.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains),
            [20, 32].contains(value.signatureHash.count),
            [value.bundleFileID, value.launcherFileID].allSatisfy({
                $0.utf8.count <= 80
                    && $0.split(separator: ":", omittingEmptySubsequences: false).count == 2
                    && $0.split(separator: ":", omittingEmptySubsequences: false).allSatisfy {
                        !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
                    }
            }),
            value.teamIdentifier.map({
                !$0.isEmpty && $0.utf8.count <= 64
                    && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            })
                ?? (UUID(
                    uuidString: String(hostIdentifier.dropFirst("com.pulkit.edith.tests.".count)))
                    != nil && hostIdentifier.hasPrefix("com.pulkit.edith.tests.")),
            value.applicationURL.isFileURL,
            value.applicationURL.host == nil || value.applicationURL.host == "",
            value.applicationURL.query == nil, value.applicationURL.fragment == nil,
            value.applicationURL.path.hasPrefix("/"), value.applicationURL.path.utf8.count <= 4096,
            !value.applicationURL.path.utf8.contains(0),
            value.applicationURL.pathExtension == "app",
            !value.applicationURL.pathComponents.contains(where: { $0.hasSuffix(".appex") }),
            value.applicationURL.standardizedFileURL == value.applicationURL,
            value.launcherURL == value.applicationURL.appendingPathComponent("Contents/MacOS/ed"),
            let infoData = try? UsageDataFiles.readRegularFile(
                at: value.applicationURL.appendingPathComponent("Contents/Info.plist"),
                maximumBytes: 65_536),
            let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil)
                as? [String: Any],
            info["CFBundleIdentifier"] as? String == hostIdentifier,
            info["CFBundleVersion"] as? String == value.buildVersion,
            info["CFBundlePackageType"] as? String == "APPL",
            info["CFBundleExecutable"] as? String == "Edith",
            ["NSExtension", "EdithContainedRole", "EdithExtensionID", "EdithHostIdentifier"]
                .allSatisfy({ info[$0] == nil }),
            (try? FileManager.default.destinationOfSymbolicLink(atPath: value.launcherURL.path))
                == "../Resources/ed-launcher",
            FileManager.default.isExecutableFile(atPath: value.launcherURL.path),
            let resource = try? UsageDataFiles.readRegularFile(
                at: value.applicationURL.appendingPathComponent("Contents/Resources/ed-launcher"),
                maximumBytes: 65_536),
            UsageMachinesPeer.hash(resource) == value.launcherSHA256
        else { return nil }
        return value.launcherURL.path
    }

    public static func defaultExecutable(
        bundle: Bundle = .main, fileManager: FileManager = .default
    ) -> String? {
        bundle.executableURL.flatMap { launcher(beside: $0, fileManager: fileManager) }
    }

    static func launcher(beside executable: URL, fileManager: FileManager = .default) -> String? {
        let launcher = executable.deletingLastPathComponent().appendingPathComponent("ed")
            .standardizedFileURL
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
        if let client = await UsageUIClient.current {
            let change = try await client.value(
                connected ? "usage.statusline.install" : "usage.statusline.remove",
                as: UsageStatusLineChangeResponse.self)
            guard let result = Change(rawValue: change.change) else {
                throw ExtensionPeerError.invalidRequest
            }
            return result
        }
        guard let service = await UsageWorkerOperations.statusLineCommands else {
            throw ExtensionPeerError.unavailable
        }
        let response = try await service.execute(
            connected ? "usage.statusline.install" : "usage.statusline.remove",
            payload: Data("{}".utf8))
        let change = try JSONDecoder().decode(UsageStatusLineChangeResponse.self, from: response)
        guard let result = Change(rawValue: change.change) else {
            throw ExtensionPeerError.invalidRequest
        }
        return result
    }

    public static func isConnected(settings url: URL = settingsURL()) async -> Bool {
        if let client = await UsageUIClient.current {
            return
                (try? await client.value(
                    "usage.statusline.status", as: UsageStatusLineStatusResponse.self))?.installed
                ?? false
        }
        return isInstalled(settings: url)
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

    static func configuredCommand(settings: URL) throws -> String? {
        try readSettings(settings).flatMap(statusCommand)
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
