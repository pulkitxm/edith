import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchAlertsTests {
    @Test func permissionHintFiresOnceOnTheSecondPrompt() throws {
        let suite = "host.notch.alerts." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!HostPermissionPromptTracker.record(defaults: defaults))
        #expect(HostPermissionPromptTracker.record(defaults: defaults))
        #expect(!HostPermissionPromptTracker.record(defaults: defaults))
    }

    @Test func updateReadyForwardsTheVersionAndNotifies() async throws {
        let namespace = "host.notch.alerts." + UUID().uuidString
        var notified: [String] = []
        let alerts = HostNotchAlerts(namespace: namespace, version: { "0.0.400" }) {
            notified.append($0)
        }
        alerts.start()
        defer { alerts.stop() }
        var received: [String: String] = [:]
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: HostNotchAlerts.notificationName(namespace: namespace), object: nil,
            queue: .main
        ) { note in received = (note.userInfo as? [String: String]) ?? [:] }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        NotificationCenter.default.post(
            name: Notification.Name(HostUpdateEvents.ready), object: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(notified == ["0.0.400"])
        #expect(received["kind"] == "updateReady")
        #expect(received["version"] == "0.0.400")
    }
}
