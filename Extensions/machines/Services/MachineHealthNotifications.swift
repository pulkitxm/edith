import EdithExtensionSupport
import Foundation
import UserNotifications

public enum MachineHealthNotifications {
    public static func send(_ alert: MachineAlert) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
    }
}

@MainActor final class MachineHealthLifecycle {
    static let jobID = "machines.health"
    private let monitor: MachineHealthMonitor
    private let interval: @MainActor () -> TimeInterval?
    private let settings: @MainActor () -> MachineHealthPolicySettings
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var pending: Task<MachineHealthSnapshot, Never>?
    private var lastCompleted: Date?
    private var started = false
    private var stopped = false
    private(set) var latest: MachineHealthSnapshot?

    init(
        monitor: MachineHealthMonitor = MachineHealthMonitor(),
        interval: @escaping @MainActor () -> TimeInterval? = { 300 },
        settings: @escaping @MainActor () -> MachineHealthPolicySettings = {
            MachineHealthPolicySettings.current()
        },
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.monitor = monitor; self.interval = interval; self.settings = settings
        self.now = now; self.sleep = sleep
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        reschedule()
    }

    func reschedule() {
        guard started else { return }
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.started, let interval = self.interval(),
                    interval.isFinite, interval > 0
                else { return }
                let delay =
                    self.lastCompleted.map { max(0, interval - self.now().timeIntervalSince($0)) }
                    ?? 0
                if delay > 0 {
                    do { try await self.sleep(.seconds(delay)) } catch { return }
                    continue
                }
                let policy = self.settings()
                if policy.notifyDown || policy.notifyDiskFull {
                    _ = await self.refresh()
                } else {
                    self.lastCompleted = self.now()
                }
            }
        }
    }

    func refresh() async -> MachineHealthSnapshot {
        guard !stopped else {
            return latest ?? .init(checkedAt: now(), machines: [], skipped: true)
        }
        if let pending { return await pending.value }
        let monitor = monitor
        let run = Task { await monitor.run() }
        pending = run
        let snapshot = await run.value
        if pending == run {
            pending = nil; lastCompleted = now()
            if started { latest = snapshot }
        }
        return snapshot
    }

    func stop() async {
        started = false; stopped = true
        let task = task; self.task = nil; task?.cancel()
        let pending = pending; self.pending = nil; pending?.cancel()
        await task?.value
        _ = await pending?.value
    }
}
