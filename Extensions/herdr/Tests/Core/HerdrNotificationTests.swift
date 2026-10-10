import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrExtension

@MainActor @Suite(.serialized) struct HerdrNotificationTests {
    @Test func originalDefaultsAndStuckBoundsRoundTrip() throws {
        let defaults = makeDefaults()
        let initial = HerdrAttentionSettings(defaults: defaults)
        #expect(initial.blocked && initial.finished && initial.errors)
        #expect(!initial.stuck && !initial.openDiff && initial.stuckMinutes == 10)
        defaults.set(-50, forKey: HerdrAttentionSettings.Keys.stuckMinutes)
        #expect(HerdrAttentionSettings(defaults: defaults).stuckMinutes == 2)
        defaults.set(500, forKey: HerdrAttentionSettings.Keys.stuckMinutes)
        #expect(HerdrAttentionSettings(defaults: defaults).stuckMinutes == 120)
        var settings = initial
        settings.blocked = false
        settings.finished = false
        settings.errors = false
        settings.stuck = true
        settings.openDiff = true
        settings.stuckMinutes = 25
        settings.save(in: defaults)
        #expect(HerdrAttentionSettings(defaults: defaults) == settings)
    }

    @Test func blockedFinishedErrorAndOptionalDiffUseOriginalScreenClassifier() async {
        let defaults = makeDefaults()
        var delivered: [HerdrNotification] = []
        var opened: [HerdrOpenRequest] = []
        let service = HerdrNotificationService(
            defaults: defaults, queueURL: queueURL(),
            attention: .init(
                inspect: { probes in
                    Dictionary(
                        uniqueKeysWithValues: probes.map {
                            (
                                $0.agent.id,
                                HerdrAttentionEvidence(
                                    screen: HerdrPaneScreen(raw: $0.agent.title), changes: 2)
                            )
                        })
                }, decider: { nil }, appIsRunning: { true }),
            deliver: { delivered.append($0) }, remove: { _ in }, open: { opened.append($0) })
        await service.evaluate(hosts(.blocked, title: "Approve this command?"))
        #expect(delivered.count == 1 && delivered[0].title.contains("needs approval"))
        #expect(delivered[0].action?.view == .agent)
        await service.evaluate(hosts(.working, title: "Working"))
        await service.evaluate(hosts(.done, title: "Done"))
        #expect(delivered.last?.action?.view == .diff && opened.isEmpty)
        defaults.set(true, forKey: HerdrAttentionSettings.Keys.openDiffWhenFinished)
        defaults.set(false, forKey: HerdrAttentionSettings.Keys.notifyWhenFinished)
        await service.evaluate(hosts(.working, title: "Working"))
        await service.evaluate(hosts(.done, title: "Done"))
        #expect(opened.count == 1 && opened[0].view == .diff && delivered.count == 2)
        await service.evaluate(hosts(.working, title: "Working"))
        await service.evaluate(hosts(.done, title: "Error: tests failed"))
        #expect(delivered.last?.title.contains("hit an error") == true && opened.count == 1)
        service.shutdown()
    }

    @Test func staleInspectionsCancellationPrivacyAndDisableCannotDeliver() async {
        let defaults = makeDefaults()
        var entered = false
        var resume: CheckedContinuation<Void, Never>?
        var delivered: [HerdrNotification] = []
        let service = HerdrNotificationService(
            defaults: defaults, queueURL: queueURL(),
            attention: .init(
                inspect: { _ in
                    await MainActor.run { entered = true }
                    await withCheckedContinuation { continuation in
                        Task { @MainActor in resume = continuation }
                    }
                    return [:]
                }, decider: { nil }, appIsRunning: { true }),
            deliver: { delivered.append($0) }, remove: { _ in }, open: { _ in })
        let pending = Task { await service.evaluate(hosts(.blocked, title: "Question?")) }
        while !entered || resume == nil { await Task.yield() }
        await service.evaluate(hosts(.working, title: "Working"))
        resume?.resume()
        await pending.value
        #expect(delivered.isEmpty)
        await service.evaluate(hosts(.blocked, title: "Question?"), hidden: true)
        service.shutdown()
        await service.evaluate(hosts(.blocked, title: "Question?"))
        #expect(delivered.isEmpty)
    }

    @Test func initialFinishedStateDoesNotNotifyAndSettingsRemoveOwnedNotifications() async {
        let defaults = makeDefaults()
        var delivered: [HerdrNotification] = []
        var removed: [String] = []
        let service = HerdrNotificationService(
            defaults: defaults, queueURL: queueURL(),
            attention: .init(inspect: { _ in [:] }, decider: { nil }, appIsRunning: { false }),
            deliver: { delivered.append($0) }, remove: { removed += $0 }, open: { _ in })
        await service.evaluate(hosts(.done, title: "Done"))
        #expect(delivered.isEmpty)
        await service.evaluate(hosts(.blocked, title: "Question?"))
        #expect(delivered.count == 1)
        defaults.set(false, forKey: HerdrAttentionSettings.Keys.notifyWhenBlocked)
        service.reconcile(HerdrAttentionSettings(defaults: defaults))
        #expect(removed == delivered.map(\.identifier))
        service.shutdown()
    }

    @Test func failedDeliveryRetriesFromOwnedQueueAndExpires() async throws {
        let defaults = makeDefaults()
        let url = queueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        var attempts = 0
        let first = HerdrNotificationService(
            defaults: defaults, queueURL: url,
            attention: .init(inspect: { _ in [:] }, decider: { nil }, appIsRunning: { false }),
            deliver: { _ in
                attempts += 1; throw ExtensionPeerError.unavailable
            }, remove: { _ in }, open: { _ in })
        await first.evaluate(hosts(.blocked, title: "Question?"), now: now)
        #expect(attempts == 1 && first.deliveryError != nil)
        var delivered: [HerdrNotification] = []
        let restored = HerdrNotificationService(
            defaults: defaults, queueURL: url,
            attention: .init(inspect: { _ in [:] }, decider: { nil }, appIsRunning: { false }),
            deliver: { delivered.append($0) }, remove: { _ in }, open: { _ in })
        await restored.evaluate(hosts(.working, title: "Working"), now: now.addingTimeInterval(1))
        #expect(delivered.count == 1 && restored.deliveryError == nil)
        restored.shutdown()
        first.shutdown()
    }

    @Test func originalStuckDetectionRequiresUnchangedScreenAndSuppressesRepeats() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: HerdrAttentionSettings.Keys.notifyWhenStuck)
        defaults.set(2, forKey: HerdrAttentionSettings.Keys.stuckMinutes)
        var delivered: [HerdrNotification] = []
        let service = HerdrNotificationService(
            defaults: defaults, queueURL: queueURL(),
            attention: .init(
                inspect: { probes in
                    Dictionary(
                        uniqueKeysWithValues: probes.map {
                            (
                                $0.agent.id,
                                HerdrAttentionEvidence(
                                    screen: HerdrPaneScreen(raw: "Compiling the project"))
                            )
                        })
                }, decider: { nil }, appIsRunning: { false }),
            deliver: { delivered.append($0) }, remove: { _ in }, open: { _ in })
        let now = Date()
        await service.evaluate(hosts(.working, title: "Working"), now: now)
        await service.evaluate(hosts(.working, title: "Working"), now: now.addingTimeInterval(120))
        #expect(delivered.isEmpty)
        await service.evaluate(hosts(.working, title: "Working"), now: now.addingTimeInterval(240))
        #expect(delivered.count == 1 && delivered[0].title.contains("looks stuck"))
        await service.evaluate(hosts(.working, title: "Working"), now: now.addingTimeInterval(360))
        #expect(delivered.count == 1)
        service.shutdown()
    }

    private func queueURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "herdr-notification-fixture-" + UUID().uuidString
        ).appendingPathComponent("queue.json")
    }
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "herdr.notification.fixture." + UUID().uuidString)!
    }
    private func hosts(_ status: HerdrAgentStatus, title: String) -> [HerdrHostSnapshot] {
        [
            .init(
                id: "local", name: "Synthetic", isLocal: true, herdrPresent: true, reachable: true,
                agents: [
                    .make(
                        machineID: "local", machineName: "Synthetic", machineIsLocal: true,
                        sshTarget: nil, session: "mock", pane: "p1", kind: "Synthetic",
                        status: status,
                        title: title, workspace: "mock", cwd: "/tmp/mock")
                ])
        ]
    }
}
