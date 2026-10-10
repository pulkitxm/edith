import Darwin
import Foundation
import Testing
@testable import VirtualCameraExtension

@Suite(.serialized) @MainActor struct CameraAppRuntimeTests {
    @Test func malformedStartupCannotAllocateAWorker() {
        let runtime = ExtensionRuntime()
        #expect((runtime.execute(["operation": "start"]) as? NSDictionary)?["ok"] as? Bool == false)
        let status = runtime.execute(["operation": "status"]) as? NSDictionary
        #expect(status?["running"] as? Bool == false)
        let description = runtime.execute(["operation": "describe"]) as? NSDictionary
        #expect(description?["id"] as? String == "virtualCamera")
        #expect(description?["role"] as? String == "app")
    }

    @Test func syntheticWorkerDrainsResourcesAndRetainsSavedSettings() async throws {
        try await fixture { defaults in
            var state = VirtualCameraState(privacy: .stopped)
            state.composition.framing.zoom = 2
            VirtualCameraStore.save(state, to: defaults)
            let worker = CameraAppWorker(defaults: defaults, host: "com.pulkit.edith.tests.worker")
            #expect(worker.model.state.composition.framing.zoom == 2)
            #expect(!worker.engine.streaming)
            try await worker.prepareDisable()
            #expect(worker.draining)
            #expect(worker.engine.isStopped)
            #expect(!defaults.bool(forKey: CameraAppWorker.pendingKey))
            #expect(VirtualCameraStore.load(defaults).composition.framing.zoom == 2)
            await #expect(throws: (any Error).self) {
                try await worker.surface.execute("surface.snapshot", payload: Data("{}".utf8))
            }
            await worker.drain()
        }
    }

    @Test func pendingDisableSurvivesRestartWithoutResumingCameraOrAudio() async throws {
        try await fixture { defaults in
            defaults.set(true, forKey: CameraAppWorker.pendingKey)
            let worker = CameraAppWorker(defaults: defaults, host: "com.pulkit.edith.tests.worker")
            #expect(worker.draining)
            #expect(!worker.engine.streaming)
            #expect(worker.client.currentStatus == nil)
            #expect(defaults.bool(forKey: CameraAppWorker.pendingKey))
            try await worker.prepareDisable()
            #expect(worker.engine.isStopped)
            #expect(!defaults.bool(forKey: CameraAppWorker.pendingKey))
        }
    }

    @Test func recoveryIntentStartsIdleWithoutAnExistingFeatureMarker() async throws {
        let original = ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"]
        setenv("EDITH_EXTENSION_RECOVERY_ONLY", "1", 1)
        defer {
            if let original {
                setenv("EDITH_EXTENSION_RECOVERY_ONLY", original, 1)
            } else {
                unsetenv("EDITH_EXTENSION_RECOVERY_ONLY")
            }
        }
        try await fixture { defaults in
            #expect(!defaults.bool(forKey: CameraAppWorker.pendingKey))
            let worker = CameraAppWorker(defaults: defaults, host: "com.pulkit.edith.tests.worker")
            #expect(worker.draining)
            #expect(!worker.engine.streaming)
            #expect(worker.client.currentStatus == nil)
            try await worker.prepareDisable()
            #expect(worker.engine.isStopped)
            #expect(!defaults.bool(forKey: CameraAppWorker.pendingKey))
        }
    }

    private func fixture(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suite = "edith.camera.worker.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
        setenv("EDITH_EXTENSION_FIXTURE_HOME", root.path, 1)
        defer {
            if let original {
                setenv("EDITH_EXTENSION_FIXTURE_HOME", original, 1)
            } else {
                unsetenv("EDITH_EXTENSION_FIXTURE_HOME")
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(defaults)
    }
}
