import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import LidAwakeExtension

@Suite(.serialized) @MainActor struct LidAwakeCLIBridgeTests {
    @Test func originalCommandsRetainPreviewConfirmationAndPolicies() async throws {
        let suite = "synthetic.lid.cli." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var effects: [Bool] = []
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: {
                effects.append($0); return .applied
            }, startServices: false)
        let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { true })
        defer { worker.shutdown() }
        let status = try await LidAwakeCLIExecution.run(
            .init(arguments: ["status", "--json"]), worker: worker)
        #expect(
            status.exitCode == 0 && status.stderr.isEmpty && status.stdout.contains("helperStatus"))
        let preview = try await LidAwakeCLIExecution.run(
            .init(arguments: ["on", "--json"]), worker: worker)
        #expect(
            preview.exitCode == 0 && preview.stdout.contains("\"performed\": false")
                && effects.isEmpty)
        let on = try await LidAwakeCLIExecution.run(
            .init(arguments: ["on", "--yes", "--json"]), worker: worker)
        #expect(on.exitCode == 0 && effects == [true])
        let off = try await LidAwakeCLIExecution.run(
            .init(arguments: ["off", "--json"]), worker: worker)
        #expect(off.exitCode == 0 && effects == [true, false])
        for args in [["--help"], ["battery", "--help"], ["restore-on-quit", "--help"]] {
            let help = try await LidAwakeCLIExecution.run(.init(arguments: args), worker: worker)
            #expect(help.exitCode == 0 && help.stdout.contains("USAGE:") && help.stderr.isEmpty)
        }
        let invalid = try await LidAwakeCLIExecution.run(
            .init(arguments: ["battery", "999"]), worker: worker)
        #expect(invalid.exitCode != 0 && invalid.stdout.isEmpty && !invalid.stderr.isEmpty)
        #expect(LidAwakeCLIEnvironment.worker == nil)
    }
    @Test func remoteSessionPreferencesAndStopUseOwningWorker() async throws {
        let suite = "synthetic.lid.remote." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: { _ in
                Issue.record("No privileged effect expected"); return .applied
            }, startServices: false)
        let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { false })
        let surface = LidAwakeSurface(worker: worker, privacy: { [:] })
        let bridge = Bridge(surface: surface)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let model = LidAwakeSettingsModel(client: client)
        model.setSession(.oneHour)
        for _ in 0..<1000 {
            if LidAwakeState.session(defaults) == .oneHour { break }; await Task.yield()
        }
        #expect(LidAwakeState.session(defaults) == .oneHour)
        model.stop(); client.invalidate(); worker.shutdown()
        model.setSession(.indefinite)
        #expect(LidAwakeState.session(defaults) == .oneHour)
    }
    @MainActor private final class Bridge: NSObject {
        let surface: LidAwakeSurface
        let registry = ExtensionCommandRegistry()
        init(surface: LidAwakeSurface) { self.surface = surface }
        @MainActor @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            registry.invoke([
                "token": request.token.uuidString, "command": request.operation,
                "payload": request.payload,
            ]) { bytes, error in
                completion(
                    (try? ExtensionEngineWire.encode(
                        ExtensionEngineReply(
                            token: request.token, ok: error == nil && bytes != nil,
                            payload: bytes as Data? ?? Data("{}".utf8)))) ?? Data())
            } execute: { [surface] in
                try await surface.execute($0, payload: $1)
            }
        }
        @MainActor @objc func cancel(_ token: String) { registry.cancel(token) }
    }
}
