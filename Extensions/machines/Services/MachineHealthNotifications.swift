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
    private let monitor: MachineHealthMonitor
    private let interval: Duration
    private var task: Task<Void, Never>?
    private(set) var latest: MachineHealthSnapshot?

    init(monitor: MachineHealthMonitor = MachineHealthMonitor(), interval: Duration = .seconds(60))
    {
        self.monitor = monitor
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let policy = MachineHealthPolicySettings.current()
                guard policy.notifyDown || policy.notifyDiskFull else {
                    do { try await Task.sleep(for: interval) } catch { return }
                    continue
                }
                let snapshot = await monitor.run()
                guard !Task.isCancelled else { return }
                latest = snapshot
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stop() async {
        let task = task
        self.task = nil
        task?.cancel()
        await task?.value
    }
}
