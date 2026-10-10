import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostHerdrInteractionsTests {
    @Test func cancelledQuitDrainsRequestsAndKeepsTheOriginalInteractionsAvailable() async throws {
        let bytes = try JSONSerialization.data(withJSONObject: [
            "identifier": "com.example.synthetic.interactions",
            "supportDirectory": "file:///tmp/synthetic-interactions", "extensionID": "herdr",
            "version": "1", "theme": "accent", "appearance": "system", "zoom": 1,
            "recoveryOnly": false,
        ])
        let configuration = try JSONDecoder().decode(HostWorkerConfiguration.self, from: bytes)
        let presentation = UUID()
        let request = HostWorkerNavigationRequest(
            configuration: configuration, section: "agentActivity", presentationID: presentation,
            location: "settings", folderChoice: true)
        let origin = HostFolderChoiceOrigin(
            extensionID: "herdr", version: "1", presentationID: presentation,
            enginePID: 42, engineGeneration: "synthetic-engine", rendererPID: 43,
            rendererGeneration: "synthetic-renderer", windowRegistration: UUID())
        var selections = 0
        var selectionFinished = false
        var prepares = 0
        var preparationFinished = false
        var restored = 0
        let chooser = HostFolderChoiceCoordinator(
            origin: { _ in origin },
            select: { _ in
                selections += 1
                if selections == 1 {
                    defer { selectionFinished = true }
                    try await Task.sleep(for: .seconds(10))
                }
                return .init(selectedPath: "/synthetic/project")
            }, cancelSelection: { _ in })
        let router = HostHerdrNotificationRouter(currentVersion: { "1" }) { _ in
            prepares += 1
            if prepares == 1 {
                defer { preparationFinished = true }
                try await Task.sleep(for: .seconds(10))
            }
            throw HostWorkerError.rejected
        }
        let interactions = HostHerdrInteractions(
            folderChoice: chooser, notifications: router,
            bindDelegate: { _ in { restored += 1 } })
        let delegate = HostApplicationDelegate()
        interactions.install(delegate: delegate)
        let notification = try HostHerdrNotificationRequest(userInfo: [
            "identifier": "synthetic-notification", "title": "Synthetic agent",
            "body": "Synthetic event", "agentID": "synthetic-agent",
            "hostID": "synthetic-host", "view": "agent",
        ])
        let selection = Task { try await interactions.chooseFolder(request) }
        let received = Task { try await delegate.receiveNotification(notification) }
        let deadline = ContinuousClock.now + .seconds(2)
        while selections == 0 || prepares == 0 {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.timedOut }
            await Task.yield()
        }
        await interactions.cancelPending()
        #expect(selectionFinished && preparationFinished)
        await #expect(throws: CancellationError.self) { try await selection.value }
        await #expect(throws: CancellationError.self) { try await received.value }
        #expect(chooser.pendingCount == 0 && router.pendingCount == 0)
        #expect(delegate.notificationClick != nil && restored == 0)
        #expect(try await interactions.chooseFolder(request).selectedPath == "/synthetic/project")
        await #expect(throws: HostWorkerError.rejected) {
            try await delegate.receiveNotification(notification)
        }
        #expect(selections == 2 && prepares == 2)
        await interactions.stop()
        #expect(delegate.notificationClick == nil && restored == 1)
        await #expect(throws: HostWorkerError.rejected) {
            try await interactions.chooseFolder(request)
        }
    }
}
