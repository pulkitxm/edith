import EdithStudio
import EdithExtensionSupport
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioUIFacadeTests {
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready())
    }

    @Test func facadeActionsReadAndMutateRealOwnedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "studio-facade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "studio.facade.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = StudioModel(defaults: defaults, loadsState: false)
        defer { model.shutdown() }
        let facade = StudioUIFacade { operation, payload in
            if operation.hasPrefix("studio.ui.") {
                return try await StudioUICommands.execute(operation, payload: payload, model: model)
            }
            return try await StudioCommands.execute(operation, payload: payload, model: model)
        }
        defer { facade.stop() }
        let file = root.appendingPathComponent("synthetic.txt")
        let bytes = Data("Synthetic facade source\n".utf8)
        try bytes.write(to: file)
        facade.add([file])
        try await waitUntil { facade.state?.files.count == 1 || facade.failure != nil }
        #expect(facade.failure == nil)
        #expect(facade.state?.files.first?.url == file)
        let facts = try await facade.facts(file)
        #expect(facts.bytes == bytes.count && facts.exists)
        facade.remove([file])
        try await waitUntil { facade.state?.files.isEmpty == true || facade.failure != nil }
        #expect(try StudioMediaLibrary.list(defaults: defaults).isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
        try StudioMediaLibrary.add([file], defaults: defaults)
        try FileManager.default.removeItem(at: file)
        facade.clearMissing()
        try await waitUntil { (try? StudioMediaLibrary.list(defaults: defaults).isEmpty) == true }
        #expect(facade.failure == nil)
    }

    @Test func facadeRejectsMalformedRepliesAndPreservesLastContent() async throws {
        let model = StudioModel(loadsState: false)
        defer { model.shutdown() }
        var malformed = false
        let facade = StudioUIFacade { operation, payload in
            if malformed { return Data("{\"files\":null}".utf8) }
            return try await StudioUICommands.execute(operation, payload: payload, model: model)
        }
        defer { facade.stop() }
        facade.refresh()
        try await waitUntil { facade.state != nil || facade.failure != nil }
        try #require(facade.state != nil && facade.failure == nil)
        let count = facade.state?.files.count
        malformed = true
        facade.refresh()
        try await waitUntil { facade.failure != nil }
        #expect(facade.state?.files.count == count)
    }

    @Test func newerRefreshAndStopRejectLateNativeReplies() async throws {
        let model = StudioModel(loadsState: false)
        defer { model.shutdown() }
        let payload = try await StudioUICommands.execute(
            "studio.ui.state", payload: Data("{}".utf8), model: model)
        var pending: [CheckedContinuation<Data, Error>] = []
        var invalidations = 0
        let facade = StudioUIFacade(
            invoke: { _, _ in
                try await withCheckedThrowingContinuation { pending.append($0) }
            }, invalidate: { invalidations += 1 })
        facade.refresh()
        try await waitUntil { pending.count == 1 }
        facade.refresh()
        try await waitUntil { pending.count == 2 }
        pending[1].resume(returning: payload)
        try await waitUntil { facade.state != nil }
        pending[0].resume(returning: Data("invalid stale reply".utf8))
        await Task.yield()
        #expect(facade.failure == nil)
        facade.refresh()
        try await waitUntil { pending.count == 3 }
        facade.stop()
        facade.stop()
        pending[2].resume(returning: Data("late disabled reply".utf8))
        await Task.yield()
        #expect(invalidations == 1 && facade.isStopped && facade.failure == nil)
        await #expect(throws: ExtensionEngineError.self) {
            try await facade.facts(URL(fileURLWithPath: "/synthetic/disabled"))
        }
    }

    @Test func originalRemoteModelRunsNativeToolAndPersistsOwnedPreferences() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await VideoEditorServiceTests.movie(in: root)
        let image = root.appendingPathComponent("synthetic.png")
        let suite = "studio.remote-model.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StudioModel(defaults: defaults, loadsState: false)
        defer { engine.shutdown() }
        var invalidations = 0
        let facade = StudioUIFacade(
            invoke: { operation, payload in
                if operation.hasPrefix("studio.ui.") {
                    return try await StudioUICommands.execute(
                        operation, payload: payload, model: engine)
                }
                return try await StudioCommands.execute(operation, payload: payload, model: engine)
            }, invalidate: { invalidations += 1 })
        let remote = StudioModel(defaults: defaults, facade: facade)
        defer { remote.shutdown() }
        #expect(remote.files.isEmpty)
        remote.start()
        remote.add([image])
        try await waitUntil { remote.files.first?.url == image || remote.message != nil }
        #expect(remote.message == nil)
        remote.setDestination(mode: StudioDestinationMode.folder.rawValue, folder: root.path)
        try await waitUntil { defaults.string(forKey: AppStorageKeys.Studio.folder) == root.path }
        #expect(defaults.string(forKey: AppStorageKeys.Studio.destination) == "folder")
        let tool = try #require(StudioCatalog.tool("image.rotate"))
        remote.openRunner(tool, with: [image])
        let job = try #require(remote.jobs.first)
        #expect(job.facade === facade && engine.jobs.isEmpty)
        remote.run(job)
        try await waitUntil { job.phase != .running }
        #expect(job.phase == .finished)
        let result = try #require(job.result)
        let output = try #require(result.outputs.first)
        #expect(output.bytes > 0 && output.url != image)
        #expect(StudioImageIO.info(output.url)?.width == 64)
        #expect(engine.jobs.first?.id == job.id)
        #expect(remote.files.contains { $0.url == image })
        remote.shutdown()
        #expect(invalidations == 1 && facade.isStopped)
        await engine.stopAndWait()
    }

    @Test func engineAdmissionRejectsUnknownFieldsAndNonlocalPaths() async throws {
        let model = StudioModel(loadsState: false)
        defer { model.shutdown() }
        for (operation, object) in [
            ("studio.ui.state", ["unknown": "field"]),
            ("studio.ui.facts", ["path": "https://example.invalid/file"]),
            ("studio.ui.facts", ["path": "relative/file"]),
            ("studio.ui.unknown", [:]),
        ] {
            let data = try JSONSerialization.data(withJSONObject: object)
            await #expect(throws: (any Error).self) {
                try await StudioUICommands.execute(operation, payload: data, model: model)
            }
        }
    }
}
