import EdithCore
import Foundation

public enum AppUpdateSource: String, CaseIterable, Codable, Sendable {
    case homebrewCask
    case homebrewFormula
    case appStore
    case sparkle
    case directFeed

    public var title: String {
        switch self {
        case .homebrewCask: "Homebrew Cask"
        case .homebrewFormula: "Homebrew Formula"
        case .appStore: "Mac App Store"
        case .sparkle: "Sparkle"
        case .directFeed: "App Feed"
        }
    }
}

public enum AppUpdateConfidence: String, CaseIterable, Codable, Sendable {
    case high
    case medium
    case low

    public var title: String { rawValue.capitalized }
}

public enum AppUpdateAction: String, Codable, Sendable {
    case install
    case openUpdater
}

public struct AppUpdateItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleID: String?
    public let applicationPath: String?
    public let source: AppUpdateSource
    public let currentVersion: String
    public let availableVersion: String
    public let releaseTitle: String?
    public let releaseNotes: String?
    public let releaseURL: URL?
    public let confidence: AppUpdateConfidence
    public let checkedAt: Date
    public let action: AppUpdateAction
    public let executablePath: String
    public let arguments: [String]

    public init(
        id: String, name: String, bundleID: String? = nil, applicationPath: String? = nil,
        source: AppUpdateSource, currentVersion: String, availableVersion: String,
        releaseTitle: String? = nil, releaseNotes: String? = nil, releaseURL: URL? = nil,
        confidence: AppUpdateConfidence, checkedAt: Date, action: AppUpdateAction,
        executablePath: String, arguments: [String]
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.applicationPath = applicationPath
        self.source = source
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.releaseTitle = releaseTitle
        self.releaseNotes = releaseNotes
        self.releaseURL = releaseURL
        self.confidence = confidence
        self.checkedAt = checkedAt
        self.action = action
        self.executablePath = executablePath
        self.arguments = arguments
    }

    public var command: String { ShellQuote.command([executablePath] + arguments) }
}

public struct AppUpdatePlan: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let items: [AppUpdateItem]
    public let concurrency: Int
    public let retries: Int

    public init(
        createdAt: Date = Date(), items: [AppUpdateItem], concurrency: Int = 2,
        retries: Int = 1
    ) {
        self.createdAt = createdAt
        self.items = items
        self.concurrency = min(max(concurrency, 1), 4)
        self.retries = min(max(retries, 0), 3)
    }
}

public enum AppUpdateResultStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

public struct AppUpdateResult: Codable, Equatable, Sendable {
    public let itemID: String
    public let name: String
    public let source: AppUpdateSource
    public let version: String
    public let status: AppUpdateResultStatus
    public let attempts: Int
    public let detail: String
    public let finishedAt: Date

    public init(
        itemID: String, name: String, source: AppUpdateSource, version: String,
        status: AppUpdateResultStatus, attempts: Int, detail: String, finishedAt: Date
    ) {
        self.itemID = itemID
        self.name = name
        self.source = source
        self.version = version
        self.status = status
        self.attempts = attempts
        self.detail = detail
        self.finishedAt = finishedAt
    }
}

public struct AppUpdateCenterState: Codable, Equatable, Sendable {
    public var ignoredVersions: [String: String]
    public var snoozedUntil: [String: Date]
    public var excludedBundleIDs: Set<String>
    public var history: [AppUpdateResult]
    public var lastRefresh: Date?

    public init(
        ignoredVersions: [String: String] = [:], snoozedUntil: [String: Date] = [:],
        excludedBundleIDs: Set<String> = [], history: [AppUpdateResult] = [],
        lastRefresh: Date? = nil
    ) {
        self.ignoredVersions = ignoredVersions
        self.snoozedUntil = snoozedUntil
        self.excludedBundleIDs = excludedBundleIDs
        self.history = history
        self.lastRefresh = lastRefresh
    }
}

public enum AppUpdateCenterError: LocalizedError, Equatable, Sendable {
    case confirmationRequired
    case emptyPlan
    case invalidBackupDestination

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired: "Review the update plan and confirm it explicitly."
        case .emptyPlan: "Select at least one available update."
        case .invalidBackupDestination: "Choose a regular backup file destination."
        }
    }
}

public struct AppUpdatePersistence: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = defaultURL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Edith", isDirectory: true)
            .appendingPathComponent("app-update-center.json")
    }

    public func load() -> AppUpdateCenterState {
        guard let data = try? Data(contentsOf: fileURL),
            let state = try? JSONDecoder.updateCenter.decode(AppUpdateCenterState.self, from: data)
        else { return AppUpdateCenterState() }
        return state
    }

    public func save(_ state: AppUpdateCenterState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder.updateCenter.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func visible(_ items: [AppUpdateItem], state: AppUpdateCenterState, now: Date)
        -> [AppUpdateItem]
    {
        items.filter { item in
            if let bundleID = item.bundleID, state.excludedBundleIDs.contains(bundleID) {
                return false
            }
            if state.ignoredVersions[item.id] == item.availableVersion { return false }
            if let until = state.snoozedUntil[item.id], until > now { return false }
            return true
        }
    }

    public func recording(
        _ results: [AppUpdateResult], in state: AppUpdateCenterState,
        maximumHistory: Int = 200
    ) -> AppUpdateCenterState {
        var state = state
        state.history = Array((results + state.history).prefix(maximumHistory))
        return state
    }

    public func backup(to destination: URL) throws {
        let destination = destination.standardizedFileURL
        guard !destination.hasDirectoryPath,
            destination.path != fileURL.path,
            !FileManager.default.fileExists(atPath: destination.path)
        else { throw AppUpdateCenterError.invalidBackupDestination }
        let data: Data
        if let stored = try? Data(contentsOf: fileURL) {
            data = stored
        } else {
            data = try JSONEncoder.updateCenter.encode(AppUpdateCenterState())
        }
        try data.write(to: destination, options: [.withoutOverwriting])
    }
}

public enum AppUpdateDiscovery {
    public typealias RunCommand = AppMaintenanceDiskImageInstaller.RunCommand
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static func discover(
        applications: [InstalledApplication],
        brewPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
        masPaths: [String] = ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"],
        now: Date = Date(), run: @escaping RunCommand = AppMaintenanceDiskImageInstaller.liveRun,
        fetch: @escaping Fetch = liveFetch
    ) async -> [AppUpdateItem] {
        async let managed = managedUpdates(
            applications: applications, paths: brewPaths, now: now, run: run)
        async let store = storeUpdates(
            applications: applications, paths: masPaths, now: now, run: run)
        async let feeds = feedUpdates(applications: applications, now: now, fetch: fetch)
        return merged(await managed + store + feeds)
    }

    public static func managedUpdates(
        applications: [InstalledApplication], paths: [String], now: Date,
        run: @escaping RunCommand
    ) async -> [AppUpdateItem] {
        guard let executable = paths.first(where: FileManager.default.isExecutableFile) else {
            return []
        }
        var environment = CLIToolEnvironment.sanitized()
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: ["outdated", "--json=v2"], environment: environment, timeout: 60,
            maximumOutputBytes: 2 * 1_024 * 1_024, terminatesProcessGroup: true)
        guard let result = try? await run(request), result.terminationStatus == 0 else { return [] }
        return parseHomebrew(
            result.outputData, applications: applications, executable: executable, now: now)
    }

    public static func parseHomebrew(
        _ data: Data, applications: [InstalledApplication], executable: String,
        now: Date
    ) -> [AppUpdateItem] {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let applicationsByName = Dictionary(
            grouping: applications, by: { normalizedName($0.name) })
        let casks = (document["casks"] as? [[String: Any]] ?? []).compactMap { record in
            managedItem(
                record, kind: .homebrewCask, applicationsByName: applicationsByName,
                executable: executable, now: now)
        }
        let formulae = (document["formulae"] as? [[String: Any]] ?? []).compactMap { record in
            managedItem(
                record, kind: .homebrewFormula, applicationsByName: [:],
                executable: executable, now: now)
        }
        return casks + formulae
    }

    public static func storeUpdates(
        applications: [InstalledApplication], paths: [String], now: Date,
        run: @escaping RunCommand
    ) async -> [AppUpdateItem] {
        guard let executable = paths.first(where: FileManager.default.isExecutableFile) else {
            return []
        }
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: executable), arguments: ["outdated"],
            environment: CLIToolEnvironment.sanitized(), timeout: 60,
            maximumOutputBytes: 1_024 * 1_024, terminatesProcessGroup: true)
        guard let result = try? await run(request), result.terminationStatus == 0 else { return [] }
        return parseMAS(result.output, applications: applications, executable: executable, now: now)
    }

    public static func parseMAS(
        _ output: String, applications: [InstalledApplication], executable: String,
        now: Date
    ) -> [AppUpdateItem] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let firstSpace = line.firstIndex(of: " "),
                let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"),
                open < close
            else { return nil }
            let identifier = String(line[..<firstSpace])
            let name = String(line[line.index(after: firstSpace)..<open])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let versions = line[line.index(after: open)..<close].components(separatedBy: "->")
            guard versions.count == 2 else { return nil }
            let current = versions[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let available = versions[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = applications.filter { normalizedName($0.name) == normalizedName(name) }
            let application = matches.count == 1 ? matches[0] : nil
            guard isNewer(available, than: application?.version ?? current) else { return nil }
            return AppUpdateItem(
                id: "mas:\(identifier)", name: application?.name ?? name,
                bundleID: application?.bundleID, applicationPath: application?.url.path,
                source: .appStore, currentVersion: application?.version ?? current,
                availableVersion: available, confidence: .high, checkedAt: now,
                action: .install, executablePath: executable,
                arguments: ["upgrade", identifier])
        }
    }

    public static func feedUpdates(
        applications: [InstalledApplication], now: Date, fetch: @escaping Fetch
    ) async -> [AppUpdateItem] {
        let candidates = applications.compactMap { application in
            feedURL(for: application).map { (application, $0) }
        }
        return await withTaskGroup(of: AppUpdateItem?.self) { group in
            let initialCount = min(4, candidates.count)
            var remaining = candidates.dropFirst(initialCount).makeIterator()
            for candidate in candidates.prefix(initialCount) {
                group.addTask {
                    guard let data = try? await fetch(candidate.1.url),
                        let release = parseFeed(data),
                        isNewer(release.version, than: candidate.0.version)
                    else { return nil }
                    return AppUpdateItem(
                        id: "\(candidate.1.source.rawValue):\(candidate.0.bundleID)",
                        name: candidate.0.name, bundleID: candidate.0.bundleID,
                        applicationPath: candidate.0.url.path, source: candidate.1.source,
                        currentVersion: candidate.0.version,
                        availableVersion: release.version, releaseTitle: release.title,
                        releaseNotes: release.notes, releaseURL: release.url,
                        confidence: candidate.1.source == .sparkle ? .high : .medium,
                        checkedAt: now,
                        action: .openUpdater, executablePath: "/usr/bin/open",
                        arguments: [candidate.0.url.path])
                }
            }
            var items: [AppUpdateItem] = []
            while let item = await group.next() {
                if let item { items.append(item) }
                if let candidate = remaining.next() {
                    group.addTask {
                        guard let data = try? await fetch(candidate.1.url),
                            let release = parseFeed(data),
                            isNewer(release.version, than: candidate.0.version)
                        else { return nil }
                        return AppUpdateItem(
                            id: "\(candidate.1.source.rawValue):\(candidate.0.bundleID)",
                            name: candidate.0.name, bundleID: candidate.0.bundleID,
                            applicationPath: candidate.0.url.path, source: candidate.1.source,
                            currentVersion: candidate.0.version,
                            availableVersion: release.version, releaseTitle: release.title,
                            releaseNotes: release.notes, releaseURL: release.url,
                            confidence: candidate.1.source == .sparkle ? .high : .medium,
                            checkedAt: now,
                            action: .openUpdater, executablePath: "/usr/bin/open",
                            arguments: [candidate.0.url.path])
                    }
                }
            }
            return items
        }
    }

    public static func parseFeed(
        _ data: Data
    ) -> (version: String, title: String?, notes: String?, url: URL?)? {
        guard data.count <= 2 * 1_024 * 1_024,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let version =
            firstMatch(
                #"(?:sparkle:shortVersionString|shortVersionString)\s*=\s*[\"']([^\"']+)[\"']"#,
                in: text) ?? firstMatch(#"<sparkle:shortVersionString>([^<]+)"#, in: text)
        guard let version else { return nil }
        let item = firstMatch(#"<item(?:\s[^>]*)?>([\s\S]*?)</item>"#, in: text) ?? text
        let title = cleanXML(firstMatch(#"<title(?:\s[^>]*)?>([\s\S]*?)</title>"#, in: item))
        let notes = cleanXML(
            firstMatch(
                #"<(?:description|sparkle:releaseNotesLink)(?:\s[^>]*)?>([\s\S]*?)</(?:description|sparkle:releaseNotesLink)>"#,
                in: item))
        let link = firstMatch(#"<link(?:\s[^>]*)?>([^<]+)</link>"#, in: item)
        let url = link.flatMap { validatedHTTPSURL(cleanXML($0) ?? $0) }
        return (version.trimmingCharacters(in: .whitespacesAndNewlines), title, notes, url)
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let candidate = versionCore(candidate)
        let installed = versionCore(installed)
        guard !candidate.isEmpty, candidate.lowercased() != "latest", !installed.isEmpty else {
            return false
        }
        return compareVersions(candidate, installed) == .orderedDescending
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : "0"
            let b = index < right.count ? right[index] : "0"
            if let ai = UInt64(a), let bi = UInt64(b), ai != bi {
                return ai < bi ? .orderedAscending : .orderedDescending
            }
            let order = a.localizedStandardCompare(b)
            if order != .orderedSame { return order }
        }
        return .orderedSame
    }

    public static let liveFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
            200..<300 ~= response.statusCode, data.count <= 2 * 1_024 * 1_024
        else { throw URLError(.badServerResponse) }
        return data
    }

    private static func managedItem(
        _ record: [String: Any], kind: AppUpdateSource,
        applicationsByName: [String: [InstalledApplication]], executable: String,
        now: Date
    ) -> AppUpdateItem? {
        guard let token = record["name"] as? String,
            let installedVersions = record["installed_versions"] as? [String],
            let installed = installedVersions.first,
            let available = record["current_version"] as? String,
            !installed.isEmpty, !available.isEmpty, available.lowercased() != "latest"
        else { return nil }
        let matches = applicationsByName[normalizedName(token)] ?? []
        let application = matches.count == 1 ? matches[0] : nil
        if kind == .homebrewCask, application == nil { return nil }
        let current = application?.version ?? installed
        guard isNewer(available, than: current) else { return nil }
        return AppUpdateItem(
            id: "\(kind.rawValue):\(token)", name: application?.name ?? token,
            bundleID: application?.bundleID, applicationPath: application?.url.path,
            source: kind, currentVersion: current, availableVersion: available,
            confidence: .high, checkedAt: now, action: .install,
            executablePath: executable, arguments: ["upgrade", token])
    }

    private static func feedURL(
        for application: InstalledApplication
    ) -> (url: URL, source: AppUpdateSource)? {
        guard let bundle = Bundle(url: application.url) else { return nil }
        let candidates: [(String, AppUpdateSource)] = [
            ("SUFeedURL", .sparkle), ("UpdateFeedURL", .directFeed),
            ("FeedURL", .directFeed),
        ]
        for (key, source) in candidates {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String,
                let url = validatedHTTPSURL(raw)
            else { continue }
            return (url, source)
        }
        return nil
    }

    private static func merged(_ items: [AppUpdateItem]) -> [AppUpdateItem] {
        let order: [AppUpdateSource: Int] = [
            .homebrewCask: 0, .homebrewFormula: 1, .appStore: 2, .sparkle: 3,
            .directFeed: 4,
        ]
        var seen = Set<String>()
        return items.sorted {
            let left = order[$0.source, default: 9]
            let right = order[$1.source, default: 9]
            return left == right
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : left < right
        }.filter { item in
            guard let bundleID = item.bundleID else { return true }
            return seen.insert(bundleID).inserted
        }
    }

    private static func normalizedName(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func versionParts(_ value: String) -> [String] {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func versionCore(_ value: String) -> String {
        value.split(separator: ",", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func validatedHTTPSURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme?.lowercased() == "https", url.host != nil, url.user == nil,
            url.password == nil
        else { return nil }
        return url
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func cleanXML(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutTags = value.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let decoded = withoutTags.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : String(decoded.prefix(4_000))
    }
}

private final class AppUpdateCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

public actor AppUpdateExecutor {
    public typealias RunCommand = AppMaintenanceDiskImageInstaller.RunCommand
    private var cancellation: AppUpdateCancellation?

    public init() {}

    public func execute(
        _ plan: AppUpdatePlan, confirmed: Bool,
        run: @escaping RunCommand = AppMaintenanceDiskImageInstaller.liveRun
    ) async throws -> [AppUpdateResult] {
        guard !plan.items.isEmpty else { throw AppUpdateCenterError.emptyPlan }
        guard confirmed else { throw AppUpdateCenterError.confirmationRequired }
        let token = AppUpdateCancellation()
        cancellation?.cancel()
        cancellation = token
        let results = await withTaskGroup(of: AppUpdateResult.self) { group in
            let initialCount = min(plan.concurrency, plan.items.count)
            var remaining = plan.items.dropFirst(initialCount).makeIterator()
            for item in plan.items.prefix(initialCount) {
                group.addTask {
                    await Self.execute(item, retries: plan.retries, token: token, run: run)
                }
            }
            var completed: [AppUpdateResult] = []
            while let result = await group.next() {
                completed.append(result)
                if let item = remaining.next() {
                    group.addTask {
                        await Self.execute(item, retries: plan.retries, token: token, run: run)
                    }
                }
            }
            return completed
        }
        if cancellation === token { cancellation = nil }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func cancel() { cancellation?.cancel() }

    private nonisolated static func execute(
        _ item: AppUpdateItem, retries: Int, token: AppUpdateCancellation,
        run: @escaping RunCommand
    ) async -> AppUpdateResult {
        var detail = "Update failed."
        for attempt in 1...(retries + 1) {
            guard !token.isCancelled, !Task.isCancelled else {
                return result(item, status: .cancelled, attempts: attempt - 1, detail: "Cancelled.")
            }
            do {
                let request = CLICommandRequest(
                    executableURL: URL(fileURLWithPath: item.executablePath),
                    arguments: item.arguments, environment: CLIToolEnvironment.sanitized(),
                    timeout: 30 * 60, maximumOutputBytes: 2 * 1_024 * 1_024,
                    terminatesProcessGroup: true)
                let response = try await run(request)
                if response.terminationStatus == 0 {
                    let message = item.action == .openUpdater ? "Updater opened." : "Updated."
                    return result(item, status: .succeeded, attempts: attempt, detail: message)
                }
                detail = response.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty { detail = "Command exited with \(response.terminationStatus)." }
            } catch {
                detail = error.localizedDescription
            }
        }
        return result(item, status: .failed, attempts: retries + 1, detail: detail)
    }

    private nonisolated static func result(
        _ item: AppUpdateItem, status: AppUpdateResultStatus, attempts: Int, detail: String
    ) -> AppUpdateResult {
        AppUpdateResult(
            itemID: item.id, name: item.name, source: item.source,
            version: item.availableVersion, status: status, attempts: attempts,
            detail: String(detail.prefix(2_000)), finishedAt: Date())
    }
}

public enum AppUpdateAutomationHook {
    public static let refreshCommand = "ed maintenance updates --json"

    public static func isAvailable(
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries,
        defaults: UserDefaults = SharedDefaults.store
    ) -> Bool {
        guard let automation = entries.first(where: { $0.id == "automations" }) else {
            return false
        }
        return automation.isEnabled(in: defaults)
    }
}

private extension JSONEncoder {
    static var updateCenter: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var updateCenter: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
