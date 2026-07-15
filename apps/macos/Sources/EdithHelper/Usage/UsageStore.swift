import AppKit
import EdithKit
import Foundation

struct RangeStat: Identifiable {
    let id: String
    let label: String
    let tokens: Double
    let cost: Double
}

@MainActor
final class UsageStore: ObservableObject, FeatureModule {
    @Published private(set) var session: LimitWindow?
    @Published private(set) var week: LimitWindow?
    @Published private(set) var codexSession: LimitWindow?
    @Published private(set) var codexWeek: LimitWindow?
    @Published private(set) var limitsError: String?
    @Published private(set) var limitsUpdatedAt: Date?
    @Published private(set) var refreshingLimits = false

    @Published private(set) var stats: [RangeStat] = []
    @Published private(set) var sources: [SourceInfo] = []
    @Published var selectedSources: Set<String> = [] {
        didSet { recomputeStats() }
    }
    @Published private(set) var statsGeneratedAt: Date?
    @Published private(set) var statsError: String?
    @Published private(set) var calendarDays: [DayPoint] = []

    @Published private(set) var updating = false
    @Published private(set) var log = ""
    @Published private(set) var diagnostics = ""

    private var defaultSources: [String] = []
    private var daily: [DailyRow] = []
    private var billingDay = 26

    private var cachedToken: String?
    private var retryNotBefore: Date?
    private var usageMtime: Date?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var locked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var process: Process?
    private var lastLogFlush: Date?
    private var wakeTask: Task<Void, Never>?
    private var launchObserver: NSObjectProtocol?
    private var refreshRequestObserver: NSObjectProtocol?
    private var limitsRefreshObserver: NSObjectProtocol?
    private var hasLiveLimits = false
    private var quickRetries = 0
    private var quickRetryTask: Task<Void, Never>?
    let notifier = LimitNotifier()
    private var history = LimitsHistory()
    @Published private(set) var limitPoints: [LimitPoint] = []
    private var historyMtime: Date?
    private var statusItem: LimitsStatusItem?

    var availableProviders: [LimitProvider] {
        LimitProvider.allCases.filter { limits(for: $0).isAvailable && providerEnabled($0) }
    }

    func limits(for provider: LimitProvider) -> ProviderLimits {
        switch provider {
        case .claude:
            return ProviderLimits(provider: provider, session: session, week: week)
        case .codex:
            return ProviderLimits(provider: provider, session: codexSession, week: codexWeek)
        }
    }

    func providerEnabled(_ provider: LimitProvider) -> Bool {
        let key = provider == .claude ? "claudeLimitsEnabled" : "codexLimitsEnabled"
        return SharedDefaults.store.object(forKey: key) as? Bool ?? true
    }

    nonisolated static func enabledLimitProviders(claude: Bool, codex: Bool) -> [LimitProvider] {
        [(LimitProvider.claude, claude), (.codex, codex)].compactMap { provider, enabled in
            enabled ? provider : nil
        }
    }

    init() {
        seedFromHistory()
        startPolling()

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.lifecycle.notice("going to sleep - pausing usage poll")
                self?.diag("going to sleep - pausing usage poll")
                self?.stopPolling()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let msg = "woke from sleep (locked=\(self.locked))"
                Log.lifecycle.notice("\(msg, privacy: .public)")
                self.diag(msg)
                guard !self.locked else { return }
                self.wakeTask?.cancel()
                self.wakeTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self, !self.locked else { return }
                    self.startPolling()
                }
            }
        }

        let dnc = DistributedNotificationCenter.default()
        lockObservers = [
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    Log.lifecycle.notice("screen locked - pausing usage poll")
                    self?.diag("screen locked - pausing usage poll")
                    self?.locked = true
                    self?.stopPolling()
                }
            },
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main)
            { [weak self] _ in
                Task { @MainActor in
                    Log.lifecycle.notice("screen unlocked - resuming usage poll")
                    self?.diag("screen unlocked - resuming usage poll")
                    self?.locked = false
                    self?.startPolling()
                }
            },
        ]

        if let app = NSApp, app.isRunning {
            syncStatusItem()
        } else {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncStatusItem() }
            }
        }

        refreshRequestObserver = IPC.observe(IPC.Name.requestUsageRefresh) { [weak self] in
            self?.runUpdate()
            Task { @MainActor in await self?.refreshLimits(force: true) }
        }

        limitsRefreshObserver = IPC.observe(IPC.Name.requestLimitsRefresh) { [weak self] in
            Task { @MainActor in await self?.refreshLimits(force: true) }
        }
    }

    private func seedFromHistory() {
        let now = Date()
        let fresh = { (w: LimitWindow?) -> LimitWindow? in
            w.flatMap { ($0.resetsAt ?? .distantFuture) > now ? $0 : nil }
        }
        if let last = LimitsHistory.latest(provider: .claude) {
            session = fresh(last.session)
            week = fresh(last.week)
            limitsUpdatedAt = last.date
        }
        if let last = LimitsHistory.latest(provider: .codex) {
            codexSession = fresh(last.session)
            codexWeek = fresh(last.week)
            limitsUpdatedAt = max(limitsUpdatedAt ?? .distantPast, last.date)
        }
        if let limitsUpdatedAt {
            diag("seeded last-known limits from history (\(limitsUpdatedAt.formatted()))")
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshLimits() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.lifecycle.notice("usage polling started (every 300s)")
        Task { @MainActor in
            await refreshLimits()
            await loadStats()
        }
    }

    private func stopPolling() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        Log.lifecycle.notice("usage polling stopped")
    }

    func shutdown() {
        stopPolling()
        for obs in lockObservers { DistributedNotificationCenter.default().removeObserver(obs) }
        lockObservers = []
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        process?.terminate()
        daily = []
        stats = []
        calendarDays = []
        log = ""
        diagnostics = ""
        usageMtime = nil
        limitPoints = []
        statusItem?.remove()
        statusItem = nil
        notifier.cancelReminders()
        wakeTask?.cancel()
        wakeTask = nil
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let refreshRequestObserver {
            IPC.stopObserving(refreshRequestObserver)
            self.refreshRequestObserver = nil
        }
        if let limitsRefreshObserver {
            IPC.stopObserving(limitsRefreshObserver)
            self.limitsRefreshObserver = nil
        }
        quickRetryTask?.cancel()
        quickRetryTask = nil
    }

    func syncStatusItem() {
        guard NSApp?.isRunning == true else { return }
        let on = SharedDefaults.store.object(forKey: "limitsInMenuBar") as? Bool ?? true
        if on, statusItem == nil {
            statusItem = LimitsStatusItem()
            updateStatusItem()
        }
        if !on, let item = statusItem {
            item.remove()
            statusItem = nil
        }
    }

    func refreshMenuBarItem() {
        updateStatusItem()
    }

    var nextLimitsRefresh: Date? {
        guard let fire = timer?.fireDate else { return nil }
        if let gate = retryNotBefore, gate > fire { return gate }
        return fire
    }

    func refreshLimits(force: Bool = false) async {
        if !force, let gate = retryNotBefore, gate > Date() { return }
        guard !refreshingLimits else { return }
        refreshingLimits = true
        let providers = Self.enabledLimitProviders(
            claude: providerEnabled(.claude), codex: providerEnabled(.codex))
        for provider in providers {
            switch provider {
            case .claude: await fetchLimitsOnce()
            case .codex: await fetchCodexLimitsOnce()
            }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        refreshingLimits = false
    }

    private func fetchLimitsOnce() async {
        guard let token = currentToken() else {
            limitsError = "Claude Code token not found"
            diag("token not found (keychain + credentials file both empty)")
            keepOrBlankMenuBar()
            return
        }
        do {
            let usage = try await Self.fetchUsage(token: token)
            apply(usage)
            let msg =
                "usage ok: session=\(Int((session?.percent ?? 0).rounded()))% week=\(Int((week?.percent ?? 0).rounded()))%"
            Log.usage.notice("\(msg, privacy: .public)")
            diag(msg)
            return
        } catch FetchError.unauthorized {
            diag("401 unauthorized - re-reading token and retrying once")
            Log.usage.error("401 unauthorized - re-reading token and retrying once")
            cachedToken = nil
        } catch {
            report(error)
            return
        }

        guard let fresh = currentToken() else {
            limitsError = "Claude Code token not found"
            diag("token re-read failed - keychain + credentials file both empty")
            keepOrBlankMenuBar()
            return
        }
        do {
            let usage = try await Self.fetchUsage(token: fresh)
            apply(usage)
            Log.usage.notice("recovered after token re-read")
            diag("recovered after token re-read")
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let msg: String
        switch error {
        case FetchError.unauthorized:
            limitsError = "Token expired - run claude to re-login"
            notifier.notifyTokenExpired()
            msg = "still unauthorized after re-read - token expired, keeping last-known numbers"
        case FetchError.rateLimited(let after):
            retryNotBefore = Date().addingTimeInterval(after ?? 1800)
            limitsError =
                "Rate limited by Claude - retrying at \(retryNotBefore!.formatted(date: .omitted, time: .shortened))"
            msg = "429 rate limited - backing off \(Int(after ?? 1800))s"
        default:
            limitsError = "Offline"
            msg = "fetch failed: \(error.localizedDescription)"
        }
        Log.usage.error("\(msg, privacy: .public)")
        diag(msg)
        keepOrBlankMenuBar()
        scheduleQuickRetry()
    }

    private func scheduleQuickRetry() {
        guard !hasLiveLimits, quickRetries < 6, retryNotBefore == nil else { return }
        quickRetries += 1
        diag("no live limits yet - quick retry \(quickRetries)/6 in 20s")
        quickRetryTask?.cancel()
        quickRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshLimits()
        }
    }

    private func diag(_ message: String) {
        diagnostics += "\(Self.diagTimeFormatter.string(from: Date()))  \(message)\n"
        if diagnostics.count > 20_000 { diagnostics = String(diagnostics.suffix(16_000)) }
    }

    static let diagTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func keepOrBlankMenuBar() {
        if availableProviders.isEmpty {
            statusItem?.showUnavailable()
        } else {
            updateStatusItem()
        }
    }

    private func updateStatusItem() {
        statusItem?.update(availableProviders.map(limits(for:)))
    }

    private func apply(_ usage: OAuthUsage) {
        session = usage.fiveHour.map {
            LimitWindow(percent: $0.utilization ?? 0, resetsAt: Self.parseISO($0.resetsAt))
        }
        week = usage.sevenDay.map {
            LimitWindow(percent: $0.utilization ?? 0, resetsAt: Self.parseISO($0.resetsAt))
        }
        limitsError = nil
        limitsUpdatedAt = Date()
        retryNotBefore = nil
        hasLiveLimits = true
        quickRetryTask?.cancel()
        quickRetryTask = nil
        notifier.evaluate(session: session, week: week)
        history.append(provider: .claude, session: session, week: week)
        SettingsBackup.shared.syncLimits()
        updateStatusItem()
        IPC.post(IPC.Name.limitsUpdated)
    }

    private func fetchCodexLimitsOnce() async {
        do {
            let limits = try await Task.detached(priority: .utility) {
                try Self.readCodexLimits()
            }.value
            codexSession = limits.session
            codexWeek = limits.week
            limitsUpdatedAt = Date()
            history.append(provider: .codex, session: codexSession, week: codexWeek)
            SettingsBackup.shared.syncLimits()
            updateStatusItem()
            IPC.post(IPC.Name.limitsUpdated)
            diag(
                "codex usage ok: session=\(Int((codexSession?.percent ?? 0).rounded()))% week=\(Int((codexWeek?.percent ?? 0).rounded()))%"
            )
        } catch {
            diag("codex limits unavailable: \(error.localizedDescription)")
            keepOrBlankMenuBar()
        }
    }

    private struct CodexWindow: Decodable {
        let usedPercent: Double
        let windowDurationMins: Double?
        let resetsAt: Double?
    }

    private struct CodexSnapshot: Decodable {
        let primary: CodexWindow?
        let secondary: CodexWindow?
    }

    private struct CodexRateLimitsResult: Decodable {
        let rateLimits: CodexSnapshot?
    }

    private struct CodexResponse: Decodable {
        let id: Int?
        let result: CodexRateLimitsResult?
    }

    private enum CodexLimitsError: LocalizedError {
        case executableMissing
        case unavailable

        var errorDescription: String? {
            switch self {
            case .executableMissing: return "Codex is not installed"
            case .unavailable: return "Codex limits are unavailable"
            }
        }
    }

    private nonisolated static func readCodexLimits() throws -> ProviderLimits {
        guard let executable = codexExecutable() else { throw CodexLimitsError.executableMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { process.terminate() }

        func send(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            input.fileHandleForWriting.write(data + Data("\n".utf8))
        }

        func response(id: Int) throws -> CodexResponse {
            var buffer = Data()
            while process.isRunning {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    if let value = try? JSONDecoder().decode(CodexResponse.self, from: line),
                        value.id == id
                    {
                        return value
                    }
                }
            }
            throw CodexLimitsError.unavailable
        }

        try send([
            "method": "initialize", "id": 0,
            "params": [
                "clientInfo": ["name": "edith", "title": "Edith", "version": "1.0"]
            ],
        ])
        _ = try response(id: 0)
        try send(["method": "initialized", "params": [:]])
        try send(["method": "account/rateLimits/read", "id": 1, "params": [:]])
        guard let snapshot = try response(id: 1).result?.rateLimits else {
            throw CodexLimitsError.unavailable
        }
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let mapped = windows.map { window in
            (
                duration: window.windowDurationMins ?? 0,
                value: LimitWindow(
                    percent: window.usedPercent,
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)))
            )
        }.sorted { $0.duration < $1.duration }
        let session = mapped.first { $0.duration > 0 && $0.duration < 7 * 24 * 60 }?.value
        let week = mapped.last { $0.duration >= 7 * 24 * 60 }?.value ?? mapped.last?.value
        return ProviderLimits(provider: .codex, session: session, week: week)
    }

    private nonisolated static func codexExecutable() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent("codex").path
                if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    private struct OAuthUsage: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        let fiveHour: Window?
        let sevenDay: Window?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private enum FetchError: Error {
        case unauthorized
        case rateLimited(after: TimeInterval?)
        case http(Int)
    }

    private nonisolated static func fetchUsage(token: String) async throws -> OAuthUsage {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { Log.usage.error("GET /oauth/usage -> HTTP \(code, privacy: .public)") }
        switch code {
        case 200: return try JSONDecoder().decode(OAuthUsage.self, from: data)
        case 401, 403: throw FetchError.unauthorized
        case 429:
            let after = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw FetchError.rateLimited(after: after)
        default: throw FetchError.http(code)
        }
    }

    private func currentToken() -> String? {
        if let t = cachedToken { return t }
        if let t = Self.tokenFromSecurityCLI() {
            Log.usage.notice("token read from keychain (security CLI)")
            cachedToken = t
            return t
        }
        if let t = Self.tokenFromCredentialsFile() {
            Log.usage.notice("token read from ~/.claude/.credentials.json")
            cachedToken = t
            return t
        }
        Log.usage.error("no token found - keychain and credentials file both empty")
        return nil
    }

    private nonisolated static func tokenFromSecurityCLI() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return extractToken(from: data)
    }

    private nonisolated static func tokenFromCredentialsFile() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return extractToken(from: data)
    }

    private nonisolated static func extractToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    static let ymdParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static func parseISO(_ s: String?) -> Date? { EdithDate.parseISO(s) }

    struct DailyRow: Decodable {
        let period: String
        let bySource: [String: [ModelRow]]
    }

    struct ModelRow: Decodable {
        let inputTokens: Double?
        let outputTokens: Double?
        let cacheCreationTokens: Double?
        let cacheReadTokens: Double?
        let cost: Double?
        var tokens: Double {
            (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheCreationTokens ?? 0)
                + (cacheReadTokens ?? 0)
        }
    }

    private struct UsageFile: Decodable {
        let generatedAt: String?
        let sources: [String]?
        let defaultSources: [String]?
        let sourceMeta: [String: Meta]?
        let daily: [DailyRow]
        struct Meta: Decodable { let label: String? }
    }

    func loadStats() async {
        let url = Repo.usageJSON
        let mtime =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            as? Date
        if let mtime, mtime == usageMtime { return }

        let parsed: UsageFile
        do {
            parsed = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(UsageFile.self, from: Data(contentsOf: url))
            }.value
        } catch {
            statsError = "usage.json missing - hit reload"
            diag("usage.json decode failed: \(error.localizedDescription)")
            return
        }

        usageMtime = mtime
        statsError = nil
        daily = parsed.daily
        defaultSources = parsed.defaultSources ?? parsed.sources ?? []
        let meta = parsed.sourceMeta ?? [:]
        sources = (parsed.sources ?? []).map { SourceInfo(id: $0, label: meta[$0]?.label ?? $0) }
        statsGeneratedAt = Self.parseISO(parsed.generatedAt)
        if selectedSources.isEmpty {
            selectedSources = Set(defaultSources)
        } else {
            recomputeStats()
        }
    }

    private func recomputeStats() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let ymd = { (d: Date) -> String in
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        let dow = (cal.component(.weekday, from: today) + 5) % 7
        let weekStart = cal.date(byAdding: .day, value: -dow, to: today)!
        let cycleStart: Date = {
            let day = cal.component(.day, from: today)
            let anchor = min(billingDay, cal.range(of: .day, in: .month, for: today)!.count)
            if day >= anchor {
                return cal.date(
                    bySetting: .day, value: anchor,
                    of: cal.date(from: cal.dateComponents([.year, .month], from: today))!)!
            }
            let prev = cal.date(byAdding: .month, value: -1, to: today)!
            let prevAnchor = min(billingDay, cal.range(of: .day, in: .month, for: prev)!.count)
            return cal.date(
                from: DateComponents(
                    year: cal.component(.year, from: prev),
                    month: cal.component(.month, from: prev), day: prevAnchor))!
        }()
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        let ranges: [(String, String, String)] = [
            ("Today", ymd(today), ymd(today)),
            ("Yesterday", ymd(yesterday), ymd(yesterday)),
            ("This week", ymd(weekStart), ymd(today)),
            ("This cycle", ymd(cycleStart), ymd(today)),
        ]
        stats = ranges.map { label, from, to in
            var tokens = 0.0, cost = 0.0
            for row in daily where row.period >= from && row.period <= to {
                for (source, models) in row.bySource where selectedSources.contains(source) {
                    for m in models {
                        tokens += m.tokens
                        cost += m.cost ?? 0
                    }
                }
            }
            return RangeStat(id: label, label: label, tokens: tokens, cost: cost)
        }

        var costByDay: [String: Double] = [:]
        for row in daily {
            var cost = 0.0
            for (source, models) in row.bySource where selectedSources.contains(source) {
                for m in models { cost += m.cost ?? 0 }
            }
            costByDay[row.period] = cost
        }
        var points: [DayPoint] = []
        var day = weekStart
        if let first = daily.map(\.period).min(),
            let firstDate = Self.ymdParser.date(from: first)
        {
            let start = cal.startOfDay(for: firstDate)
            let dow = (cal.component(.weekday, from: start) + 5) % 7
            day = cal.date(byAdding: .day, value: -dow, to: start)!
        }
        while day <= today {
            let key = ymd(day)
            points.append(DayPoint(id: key, date: day, cost: costByDay[key] ?? 0))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        calendarDays = points
    }

    func loadLimitHistory(provider: LimitProvider = .claude) async {
        let url = LimitsHistory.url
        let mtime =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            as? Date
        historyMtime = mtime
        let since = Date().addingTimeInterval(-24 * 3600)
        let points = await Task.detached(priority: .utility) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return [LimitPoint]()
            }
            return LimitsHistory.parse(text, since: since, provider: provider)
        }.value
        limitPoints = points
    }

    func runUpdate() {
        guard !updating,
            let script = Bundle.main.url(forResource: "refresh-usage", withExtension: nil)
        else {
            log = "✖ refresh-usage script not found in app bundle"
            return
        }
        updating = true
        log = ""
        IPC.post(IPC.Name.usageRefreshStarted)
        let dataDir = Repo.dataDir
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        lastLogFlush = nil
        flushLog(force: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, dataDir.path]
        p.currentDirectoryURL = AppData.supportDir
        p.qualityOfService = .utility
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.log += text
                if self.log.count > 20_000 { self.log = String(self.log.suffix(16_000)) }
                self.flushLog()
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.updating = false
                self.process = nil
                if proc.terminationStatus != 0 {
                    self.log += "\n✖ refresh exited with status \(proc.terminationStatus)"
                }
                SettingsBackup.shared.syncUsage()
                await self.loadStats()
                self.flushLog(force: true)
                NotificationCenter.default.post(name: .usageDataChanged, object: nil)
                IPC.post(IPC.Name.usageRefreshFinished)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            updating = false
            log = "✖ could not launch refresh-usage: \(error.localizedDescription)"
            flushLog(force: true)
        }
    }

    private func flushLog(force: Bool = false) {
        let now = Date()
        if !force, let last = lastLogFlush, now.timeIntervalSince(last) < 0.3 { return }
        lastLogFlush = now
        try? log.write(
            to: Repo.dataDir.appendingPathComponent("refresh.log"),
            atomically: true, encoding: .utf8)
    }
}

extension Notification.Name {
    static let usageDataChanged = Notification.Name("usageDataChanged")
}
