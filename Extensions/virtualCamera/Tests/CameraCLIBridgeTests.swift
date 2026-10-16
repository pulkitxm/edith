import Darwin
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import VirtualCameraExtension

@Suite(.serialized) @MainActor struct CameraCLIBridgeTests {
    @Test func originalCameraCommandsUseOwningEngineAndPreserveOBSRestriction() async throws {
        try await fixture { worker, _ in
            let status = try await CameraCLIExecution.run(
                .init(arguments: ["status", "--json"]), engine: worker.engine)
            #expect(
                status.exitCode == 0 && status.stderr.isEmpty
                    && status.stdout.contains("cameraAccess"))
            let zoom = try await CameraCLIExecution.run(
                .init(arguments: ["zoom", "2", "--json"]), engine: worker.engine)
            #expect(
                zoom.exitCode == 0 && worker.engine.snapshot().state.composition.framing.zoom == 2)
            let save = try await CameraCLIExecution.run(
                .init(arguments: ["scene", "save", "Synthetic", "--json"]), engine: worker.engine)
            #expect(
                save.exitCode == 0
                    && worker.engine.snapshot().state.scenes.contains { $0.name == "Synthetic" })
            let list = try await CameraCLIExecution.run(
                .init(arguments: ["scene", "list", "--json"]), engine: worker.engine)
            #expect(list.exitCode == 0 && list.stdout.contains("Synthetic"))
            let preview = try await CameraCLIExecution.run(
                .init(arguments: ["extension", "install", "--json"]), engine: worker.engine)
            #expect(preview.exitCode == 0 && preview.stdout.contains("false"))
            let rejected = try await CameraCLIExecution.run(
                .init(arguments: ["extension", "install", "--yes"]), engine: worker.engine)
            #expect(
                rejected.exitCode == 4 && rejected.stdout.isEmpty
                    && rejected.stderr.contains("OBS Virtual Camera"))
            let on = try await CameraCLIExecution.run(
                .init(arguments: ["on"]), engine: worker.engine)
            #expect(on.exitCode == 4 && on.stderr.contains("marketplace lifecycle"))
            for args in [
                ["frame", "--help"], ["audio", "--help"], ["screen", "--help"],
                ["record", "--help"], ["video", "--help"], ["--help"],
            ] {
                let help = try await CameraCLIExecution.run(
                    .init(arguments: args), engine: worker.engine)
                #expect(help.exitCode == 0 && help.stdout.contains("USAGE:") && help.stderr.isEmpty)
            }
            #expect(CameraCLIEnvironment.engine == nil)
        }
    }
    @Test func remoteOriginalPaneSavesOnlyThroughOwningEngineAndStopsRequests() async throws {
        try await fixture { worker, defaults in
            let bridge = Bridge(worker: worker)
            let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
            let remote = VirtualCameraPageModel(engineClient: client, defaults: defaults)
            await remote.refreshRemote()
            #expect(remote.state.output == .obs && remote.state.privacy == .stopped)
            remote.setZoom(2); remote.flushSave()
            for _ in 0..<1000 {
                if worker.engine.snapshot().state.composition.framing.zoom == 2 { break };
                await Task.yield()
            }
            #expect(
                worker.engine.snapshot().state.composition.framing.zoom == 2
                    && VirtualCameraStore.load(defaults).composition.framing.zoom == 2)
            client.invalidate(); await remote.shutdown()
            await #expect(throws: ExtensionPeerError.self) {
                try await remote.performRequest(.status)
            }
        }
    }
    @Test func livePreviewFramesAndReleaseNeverPersistOrKeepTheCameraLeased() async throws {
        try await fixture { worker, defaults in
            let stored = worker.engine.snapshot().state
            var edited = stored
            edited.composition.framing.zoom = 2
            let reply = try await worker.ui.execute(
                "camera.ui.preview", payload: JSONEncoder().encode(edited))
            #expect(reply == Data("{}".utf8))
            #expect(worker.engine.snapshot().state == stored)
            #expect(VirtualCameraStore.load(defaults) == stored)
            let frame = try JSONDecoder().decode(
                CameraUIFrame.self,
                from: await worker.ui.execute(
                    "camera.ui.frame",
                    payload: JSONSerialization.data(withJSONObject: ["after": -1])))
            #expect(frame.preview == nil)
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await worker.ui.execute(
                    "camera.ui.frame", payload: Data("{\"other\":1}".utf8))
            }
            let release = try await worker.ui.execute("camera.ui.release", payload: Data("{}".utf8))
            #expect(release == Data("{}".utf8))
        }
    }
    private func fixture(_ body: (CameraAppWorker, UserDefaults) async throws -> Void) async throws
    {
        let suite = "synthetic.camera.cli." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil)
        VirtualCameraStore.save(VirtualCameraState(privacy: .stopped), to: defaults)
        let layout = try CameraSelectedPackageLayoutTests.Fixture(
            hostIdentifier: "com.pulkit.edith.tests.cli")
        defer { layout.remove() }
        let worker = try CameraAppWorker(
            defaults: defaults, host: "com.pulkit.edith.tests.cli", roleURL: layout.role)
        do { try await body(worker, defaults); try await worker.prepareDisable() } catch {
            await worker.drain(); throw error
        }
    }
    @MainActor private final class Bridge: NSObject {
        let worker: CameraAppWorker
        let registry = ExtensionCommandRegistry()
        init(worker: CameraAppWorker) { self.worker = worker }
        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            registry.invoke(
                [
                    "token": request.token.uuidString, "command": request.operation,
                    "payload": request.payload,
                ],
                completion: { bytes, error in
                    completion(
                        (try? ExtensionEngineWire.encode(
                            ExtensionEngineReply(
                                token: request.token, ok: error == nil && bytes != nil,
                                payload: bytes as Data? ?? Data("{}".utf8)))) ?? Data())
                },
                execute: { [worker] operation, payload in
                    if operation == "camera.request" {
                        let input =
                            try JSONSerialization.jsonObject(with: payload) as? [String: Any];
                        guard let input, let request = VirtualCameraRuntimeRequest(payload: input)
                        else { throw ExtensionPeerError.invalidRequest };
                        return try JSONEncoder().encode(
                            try await worker.engine.performRecording(request.request))
                    }
                    return try await worker.ui.execute(operation, payload: payload)
                })
        }
        @objc func cancel(_ token: String) { registry.cancel(token) }
    }
}
