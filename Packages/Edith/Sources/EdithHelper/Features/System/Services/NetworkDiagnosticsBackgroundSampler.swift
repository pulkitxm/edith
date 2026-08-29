import EdithKit
import Foundation
import UserNotifications

@MainActor
final class NetworkDiagnosticsBackgroundSampler {
    private var task: Task<Void, Never>?
    private var lastState: NetworkDiagnosticState?

    init() {}

    func sync() {
        task?.cancel()
        task = nil
        let configuration = NetworkDiagnosticsPreferences.configuration()
        guard configuration.scheduledSamplingEnabled else { return }
        task = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(Double(configuration.sampleIntervalMinutes * 60)))
                } catch {
                    return
                }
                let snapshot = await NetworkDiagnosticsEngine().diagnose(
                    configuration: configuration,
                    baseline: NetworkDiagnosticsPreferences.baseline())
                guard !Task.isCancelled else { return }
                _ = try? await NetworkDiagnosticsTimelineStore.shared.append(
                    snapshot, limit: configuration.timelineLimit)
                if configuration.notificationsEnabled,
                    self?.lastState != nil, self?.lastState != snapshot.state,
                    snapshot.state == .failed || self?.lastState == .failed
                {
                    let content = UNMutableNotificationContent()
                    content.title = "Network state changed"
                    content.body = "Diagnostics now report \(snapshot.state.rawValue)."
                    content.sound = .default
                    try? await UNUserNotificationCenter.current().add(
                        UNNotificationRequest(
                            identifier: "network-diagnostics-background", content: content,
                            trigger: nil))
                }
                self?.lastState = snapshot.state
            }
        }
    }

    func shutdown() {
        task?.cancel()
        task = nil
    }
}
