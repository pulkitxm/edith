import EdithExtensionSupport
import Foundation
import UserNotifications

actor UsageLimitAlerts {
    typealias Delivery = @Sendable ([LimitAlert], [LimitAlert]) async throws -> Void
    private struct State: Codable { var ledger: LimitAlertLedger }
    private let url: URL
    private let defaults: UserDefaults
    private let historyURL: URL
    private let delivery: Delivery
    private let jev: @Sendable () async -> (any JevDeciding)?
    private var ledger: LimitAlertLedger
    private var stopped = false

    init(
        url: URL = LimitAlertLedger.outboxURL, defaults: UserDefaults = SharedDefaults.store,
        historyURL: URL = LimitsHistory.url,
        delivery: @escaping Delivery = { try await UsageLimitAlerts.deliver($0, scheduled: $1) },
        jev: @escaping @Sendable () async -> (any JevDeciding)? = { await UsageJevPeer.current() }
    ) {
        self.url = url; self.defaults = defaults; self.historyURL = historyURL
        self.delivery = delivery; self.jev = jev;
        ledger = LimitAlertLedger.load(from: url) ?? .init()
    }

    func evaluate(_ snapshot: LimitsTopicSnapshot, now: Date = Date()) async throws {
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        let settings = LimitAlertSettings.fromDefaults(defaults)
        guard settings.master else {
            try await delivery([], [])
            return
        }
        let samples = LimitsHistory.alertSamples(
            since: now.addingTimeInterval(-LimitAlertPlanner.historySpan), url: historyURL)
        var assessments: [LimitAlertAssessment] = []
        var problems: [LimitProvider: LimitLoginProblem] = [:]
        var healthy: Set<LimitProvider> = []
        for provider in snapshot.providers where settings.providers.contains(provider.provider) {
            if let error = provider.error {
                problems[provider.provider] = .init(error: error); continue
            }
            guard provider.session != nil || provider.week != nil || provider.fable != nil else {
                continue
            }
            healthy.insert(provider.provider)
            for target in LimitAlertTarget.all
            where target.provider == provider.provider && settings.tracks(target) {
                guard let window = provider.window(for: target.slot),
                    (window.resetsAt ?? .distantFuture) > now
                else { continue }
                assessments.append(
                    LimitAlertPlanner.assess(
                        target, window: window, samples: samples[target] ?? [], now: now))
            }
        }
        let proposed = LimitAlertPlanner.plan(
            assessments, problems: problems, healthy: healthy, ledger: ledger, settings: settings,
            clock: .init(now: now))
        let gate = LimitAlertJevGate(
            decider: proposed.alerts.contains { !$0.kind.isCritical } ? await jev() : nil)
        var held: Set<String> = []
        for alert in proposed.alerts where !alert.kind.isCritical {
            if await !gate.allows(alert) { held.insert(alert.identifier) }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
        }
        let plan =
            held.isEmpty
            ? proposed
            : LimitAlertPlanner.plan(
                assessments, problems: problems, healthy: healthy, ledger: ledger,
                settings: settings, clock: .init(now: now), held: held)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try await delivery(plan.alerts, plan.scheduled)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(State(ledger: plan.ledger))
        guard data.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        try UsageDataFiles.write(data, to: url)
        ledger = plan.ledger
    }

    func shutdown() { stopped = true }

    static func removePending() async {
        let center = UNUserNotificationCenter.current()
        let identifiers = await center.pendingNotificationRequests().map(\.identifier).filter {
            $0.hasPrefix("usage.limits.")
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private static func deliver(_ alerts: [LimitAlert], scheduled: [LimitAlert]) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard
            settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        else {
            throw ExtensionPeerError.rejected("Notifications need permission in Usage settings.")
        }
        try Task.checkCancellation()
        await removePending()
        for alert in alerts + scheduled {
            try Task.checkCancellation()
            let content = UNMutableNotificationContent()
            content.title = alert.title; content.body = alert.body; content.sound = .default
            content.userInfo = ["extensionID": "usage"]
            let trigger: UNNotificationTrigger?
            if let fireAt = alert.fireAt {
                guard fireAt > Date() else { continue }
                trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, fireAt.timeIntervalSinceNow), repeats: false)
            } else {
                trigger = nil
            }
            try await center.add(
                .init(identifier: "usage." + alert.identifier, content: content, trigger: trigger))
        }
    }
}
