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
    private var knownSources: Set<String> = []
    private var daily: [DailyRow] = []
    private var billingDay = 26

    private var cachedClaudeCredential: ClaudeOAuthCredential?
    private var retryNotBefore: Date?
    private var usageMtime: Date?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var locked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshEvents: [UsageRefreshEvent] = []
    private var refreshStartedAt: Date?
    private var wakeTask: Task<Void, Never>?
    private var launchObserver: NSObjectProtocol?
    private var refreshRequestObserver: NSObjectProtocol?
    private var refreshStartedObserver: NSObjectProtocol?
    private var limitsRefreshObserver: NSObjectProtocol?
    private var machineCollectObserver: NSObjectProtocol?
    private var hasLiveLimits = false
    private var limitsRefreshStartedAt: Date?
    private var limitsRefreshGeneration = 0
    private var quickRetries = 0
    private var quickRetryTask: Task<Void, Never>?
    private var machineTask: Task<Void, Never>?
    private var pendingMachineMerge = false
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

        refreshStartedObserver = IPC.observe(IPC.Name.usageRefreshStarted) { [weak self] in
            Task { @MainActor in self?.adoptExternalRefresh() }
        }

        machineCollectObserver = IPC.observe(IPC.Name.requestUsageMachineCollect) { [weak self] in
            self?.runUpdate(forceMachines: true)
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
            Task { @MainActor in
                await self?.refreshLimits()
                self?.runUpdate()
            }
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
        refreshTask?.cancel()
        refreshTask = nil
        refreshEvents = []
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
        if let refreshStartedObserver {
            IPC.stopObserving(refreshStartedObserver)
            self.refreshStartedObserver = nil
        }
        if let limitsRefreshObserver {
            IPC.stopObserving(limitsRefreshObserver)
            self.limitsRefreshObserver = nil
        }
        quickRetryTask?.cancel()
        quickRetryTask = nil
        machineTask?.cancel()
        machineTask = nil
        if let machineCollectObserver {
            IPC.stopObserving(machineCollectObserver)
            self.machineCollectObserver = nil
        }
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
        let now = Date()
        switch LimitsRefreshGate.decide(
            force: force, inFlightSince: limitsRefreshStartedAt, retryNotBefore: retryNotBefore,
            now: now)
        {
        case .skipInFlight, .skipBackoff:
            return
        case .recoverStalled:
            let msg = "previous limits refresh never finished - starting a new one"
            Log.usage.error("\(msg, privacy: .public)")
            diag(msg)
        case .start:
            break
        }

        limitsRefreshGeneration += 1
        let generation = limitsRefreshGeneration
        limitsRefreshStartedAt = now
        refreshingLimits = true
        defer {
            if generation == limitsRefreshGeneration {
                limitsRefreshStartedAt = nil
                refreshingLimits = false
            }
        }

        let providers = Self.enabledLimitProviders(
            claude: providerEnabled(.claude), codex: providerEnabled(.codex))
        for provider in providers {
            switch provider {
            case .claude: await fetchLimitsOnce()
            case .codex: await fetchCodexLimitsOnce()
            }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func fetchLimitsOnce() async {
        guard var credential = currentClaudeCredential() else {
            limitsError = "Claude Code token not found"
            diag("token not found (keychain + credentials file both empty)")
            keepOrBlankMenuBar()
            return
        }
        do {
            if credential.shouldRefresh(at: Date()) {
                credential = try await refreshClaudeCredential(credential)
            }
            let usage = try await Self.fetchUsage(token: credential.accessToken)
            apply(usage)
            let msg =
                "usage ok: session=\(Int((session?.percent ?? 0).rounded()))% week=\(Int((week?.percent ?? 0).rounded()))%"
            Log.usage.notice("\(msg, privacy: .public)")
            diag(msg)
            return
        } catch FetchError.unauthorized {
            diag("401 unauthorized - re-reading credentials and refreshing token")
            Log.usage.error("401 unauthorized - re-reading credentials and refreshing token")
            cachedClaudeCredential = nil
        } catch {
            report(error)
            return
        }

        guard let latest = currentClaudeCredential() else {
            limitsError = "Claude Code token not found"
            diag("token re-read failed - keychain + credentials file both empty")
            keepOrBlankMenuBar()
            return
        }
        do {
            let fresh: ClaudeOAuthCredential
            if latest.accessToken != credential.accessToken,
                !latest.shouldRefresh(at: Date())
            {
                fresh = latest
            } else {
                fresh = try await refreshClaudeCredential(latest)
            }
            let usage = try await Self.fetchUsage(token: fresh.accessToken)
            apply(usage)
            Log.usage.notice("recovered after token refresh")
            diag("recovered after token refresh")
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let msg: String
        switch error {
        case FetchError.unauthorized:
            limitsError = "Claude session expired - run claude to re-login"
            notifier.notifyTokenExpired()
            msg = "token refresh unavailable or rejected - keeping last-known numbers"
        case FetchError.rateLimited(let after):
            let deadline = LimitsRefreshGate.backoffDeadline(retryAfter: after, now: Date())
            retryNotBefore = deadline
            limitsError =
                "Rate limited by Claude - retrying at \(deadline.formatted(date: .omitted, time: .shortened))"
            msg = "429 rate limited - backing off \(Int(deadline.timeIntervalSinceNow))s"
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

    private nonisolated static let codexReadTimeout: TimeInterval = 25

    private nonisolated static func readCodexLimits() throws -> ProviderLimits {
        guard let executable = codexExecutable() else { throw CodexLimitsError.executableMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = CLIToolEnvironment.sanitized()
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            Log.usage.error("codex app-server stopped responding - killing it")
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + codexReadTimeout, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
        }

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
        CLIToolEnvironment.executable(named: "codex")
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

    private nonisolated static let limitsSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private nonisolated static func fetchUsage(token: String) async throws -> OAuthUsage {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        let (data, resp) = try await limitsSession.data(for: req)
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

    private func currentClaudeCredential() -> ClaudeOAuthCredential? {
        if let cachedClaudeCredential { return cachedClaudeCredential }
        guard let credential = ClaudeCredentialStore.read() else {
            Log.usage.error("no token found - keychain and credentials file both empty")
            return nil
        }
        switch credential.source {
        case .keychain:
            Log.usage.notice("token read from keychain (security CLI)")
        case .file:
            Log.usage.notice("token read from ~/.claude/.credentials.json")
        }
        cachedClaudeCredential = credential
        return credential
    }

    private func refreshClaudeCredential(_ credential: ClaudeOAuthCredential) async throws
        -> ClaudeOAuthCredential
    {
        let now = Date()
        guard let refreshToken = credential.usableRefreshToken(at: now) else {
            throw FetchError.unauthorized
        }
        diag("refreshing Claude access token")
        let response = try await Self.fetchRefreshedClaudeToken(refreshToken: refreshToken)
        let data = try credential.updatedData(with: response, now: now)
        try ClaudeCredentialStore.persist(data, source: credential.source)
        guard let refreshed = ClaudeOAuthCredential.decode(data, source: credential.source) else {
            throw FetchError.unauthorized
        }
        cachedClaudeCredential = refreshed
        Log.usage.notice("Claude access token refreshed and saved")
        diag("Claude access token refreshed and saved")
        return refreshed
    }

    private nonisolated static func fetchRefreshedClaudeToken(refreshToken: String) async throws
        -> ClaudeOAuthRefreshResponse
    {
        var request = URLRequest(
            url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ])
        let (data, response) = try await limitsSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            return try JSONDecoder().decode(ClaudeOAuthRefreshResponse.self, from: data)
        case 400, 401, 403:
            throw FetchError.unauthorized
        case 429:
            let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw FetchError.rateLimited(after: after)
        default:
            throw FetchError.http(code)
        }
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
        let availableSources = Set(sources.map(\.id))
        selectedSources = UsageSourceSelection.reconcile(
            selected: selectedSources, known: knownSources, available: availableSources,
            defaults: Set(defaultSources))
        knownSources = availableSources
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

    func runUpdate(collectMachines: Bool = true, forceMachines: Bool = false) {
        if collectMachines { collectFromMachines(force: forceMachines) }
        guard !updating else { return }
        MachineUsageStore.prune(keeping: MachineRegistry.machines().map(\.id))
        beginTranscript()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if UsageRefreshRunner.isRunning {
                    _ = try await UsageRefreshFollower.follow { event in
                        Task { @MainActor in self.append(event) }
                    }
                } else {
                    _ = try await UsageRefreshRunner.run { event in
                        Task { @MainActor in self.append(event) }
                    }
                }
            } catch let failure as UsageRefreshFailure {
                self.append(.failure(failure.description))
            } catch {
                self.append(.failure(error.localizedDescription))
            }
            await self.finishRefresh()
        }
    }

    private func beginTranscript() {
        updating = true
        refreshStartedAt = Date()
        refreshEvents = []
        log = UsageRefreshTranscript.render([], startedAt: refreshStartedAt ?? Date())
    }

    private func append(_ event: UsageRefreshEvent) {
        refreshEvents.append(event)
        log = UsageRefreshTranscript.render(
            refreshEvents, startedAt: refreshStartedAt ?? Date())
    }

    private func finishRefresh() async {
        updating = false
        refreshTask = nil
        SettingsBackup.shared.syncUsage()
        await loadStats()
        NotificationCenter.default.post(name: .usageDataChanged, object: nil)
        if pendingMachineMerge {
            pendingMachineMerge = false
            runUpdate(collectMachines: false)
        }
    }

    private func adoptExternalRefresh() {
        guard !updating else { return }
        beginTranscript()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await UsageRefreshFollower.follow { event in
                    Task { @MainActor in self.append(event) }
                }
            } catch let failure as UsageRefreshFailure {
                self.append(.failure(failure.description))
            } catch {
                self.append(.failure(error.localizedDescription))
            }
            await self.finishRefresh()
        }
    }

    nonisolated static let machineInterval: TimeInterval = 1800

    nonisolated static func machinesDue(
        _ machines: [Machine], force: Bool, now: Date,
        collectedAt: (UUID) -> Date?
    ) -> [Machine] {
        machines.filter { machine in
            guard !force else { return true }
            guard let last = collectedAt(machine.id) else { return true }
            return now.timeIntervalSince(last) >= machineInterval
        }
    }

    private func collectFromMachines(force: Bool) {
        guard machineTask == nil else { return }
        let registry = MachineRegistry.machines()
        let due = Self.machinesDue(
            MachineUsageSelection.included(in: registry), force: force, now: Date(),
            collectedAt: { MachineUsageStore.summary(machineID: $0)?.collectedAt })
        guard !due.isEmpty else { return }
        let slugs = MachineUsageSlug.slugs(for: registry)
        diag("collecting usage from \(due.count) machine(s)")
        machineTask = Task { [weak self] in
            var collected = 0
            for machine in due {
                let slug = slugs[machine.id] ?? MachineUsageSlug.slug(for: machine.name)
                let connection = SSHConnection(machine: machine)
                do {
                    try await connection.connect()
                    let run = try await MachineUsageCollector.collect(
                        machine: machine, slug: slug, over: connection)
                    collected += 1
                    let sources = run.summary.sources.count
                    await self?.noteMachine(
                        "\(machine.name): \(run.summary.days) days from \(sources) source(s)")
                } catch {
                    await self?.noteMachine(
                        "\(machine.name): \(error.localizedDescription)")
                }
            }
            await self?.finishedCollecting(changed: collected > 0)
        }
    }

    private func noteMachine(_ message: String) {
        Log.usage.notice("machine usage \(message, privacy: .public)")
        diag("machine usage \(message)")
    }

    private func finishedCollecting(changed: Bool) {
        machineTask = nil
        guard changed else { return }
        guard !updating else {
            pendingMachineMerge = true
            return
        }
        runUpdate(collectMachines: false)
    }
}

extension Notification.Name {
    static let usageDataChanged = Notification.Name("usageDataChanged")
}
