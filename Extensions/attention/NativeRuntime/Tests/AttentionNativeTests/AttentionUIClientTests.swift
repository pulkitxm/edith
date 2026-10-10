import EdithExtensionSupport
import Foundation
import Testing

@testable import AttentionNative

@Suite(.serialized) @MainActor struct AttentionUIClientTests {
    @Test func stoppedPresentationRejectsLateSnapshotsAndQueuedActions() async throws {
        var continuation: CheckedContinuation<Data, Error>?
        var operations: [String] = []
        var invalidated = false
        let client = AttentionUIClient(
            send: { operation, _ in
                operations.append(operation)
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }, invalidate: { invalidated = true })
        let request = Task { try await client.status() }
        while continuation == nil { await Task.yield() }
        client.stop()
        continuation?.resume(
            returning: try AttentionPayload.encode(AttentionUIStatus(browserConnected: true)))
        await #expect(throws: CancellationError.self) { try await request.value }
        var published = false
        client.perform("attention.ui.focus.start") { _ in published = true }
        #expect(!published)
        #expect(invalidated)
        #expect(operations == ["attention.ui.status"])
        await #expect(throws: ExtensionPeerError.self) { try await client.status() }
    }

    @Test func remotePageReadsEngineSummaryAndSettingsWithoutOpeningLocalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AttentionDatabase(url: root.appendingPathComponent("history.sqlite"))
        let repository = AttentionRepository(
            root: root, eventSink: AttentionEventStore(store: database))
        let service = AttentionBackgroundService(
            store: database, root: root, cloudDirectory: root.appendingPathComponent("cloud"),
            cloudAvailable: { false }, collectsSystemActivity: false)
        try repository.append(
            AttentionEvent(
                id: "mock", startedAt: Date().addingTimeInterval(-90), duration: 45,
                source: .application, appName: "Mock Editor", bundleID: "example.editor"))
        let deniedRoot = root.appendingPathComponent("must-remain-absent")
        var operations: [String] = []
        let client = AttentionUIClient(send: { operation, payload in
            operations.append(operation)
            if operation == "attention.ui.status" {
                return try AttentionPayload.encode(AttentionUIStatus())
            }
            if operation == "attention.ui.summary" {
                return try await AttentionCommands.execute(
                    "attention.summary", payload: payload, service: service)
            }
            return try await AttentionCommands.execute(
                operation, payload: payload, service: service)
        })
        let model = AttentionPageModel(repository: .init(root: deniedRoot), uiClient: client)
        model.reload()
        await model.waitForReload()
        #expect(model.loaded)
        #expect(model.summary.entities.contains { $0.name == "Mock Editor" })
        #expect(!FileManager.default.fileExists(atPath: deniedRoot.path))
        model.settings.privacyLevel = .applications
        model.saveSettings()
        for _ in 0..<100 where repository.loadSettings().privacyLevel != .applications {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(repository.loadSettings().privacyLevel == .applications)
        #expect(operations.contains("attention.settings.set"))
        client.stop()
        await model.shutdown()
        await service.stop()
        try database.close()
    }

    @Test func exportedControllerRejectsUncheckedConfigurationAndEngineStartupInWorker() {
        let controller = AttentionExtensionController(bundle: .main)
        let unchecked =
            controller.execute(["operation": "configureUI", "remoteUI": true] as NSDictionary)
            as? NSDictionary
        #expect(unchecked?["ok"] as? Bool == false)
        let view = controller.execute(["operation": "view"] as NSDictionary) as? NSDictionary
        #expect(view?["ok"] as? Bool == false)
        #expect(controller.responds(to: NSSelectorFromString("prepareToStopWithCompletion:")))
        #expect(controller.responds(to: NSSelectorFromString("invoke:completion:")))
    }
}
