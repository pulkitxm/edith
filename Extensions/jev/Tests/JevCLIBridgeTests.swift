import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import JevExtension

@Suite(.serialized) @MainActor struct JevCLIBridgeTests {
    @Test func originalStatusKeyStdinAndClearPreviewUseOwnedKeyStore() async throws {
        let store = MemoryJevKeyStore()
        let engine = JevEngine(store: store)
        let status = try await JevCLIExecution.run(
            .init(arguments: ["status", "--json"]), engine: engine)
        #expect(
            status.exitCode == 0 && status.stderr.isEmpty && status.stdout.contains("notConfigured")
        )
        let saved = try await JevCLIExecution.run(
            .init(arguments: ["key", "set", "--json"]), engine: engine,
            stdin: Data("synthetic-secret".utf8))
        #expect(saved.exitCode == 0 && store.read() == .key("synthetic-secret"))
        #expect(!saved.stdout.contains("synthetic-secret") && saved.stderr.isEmpty)
        let preview = try await JevCLIExecution.run(
            .init(arguments: ["key", "clear", "--json"]), engine: engine)
        #expect(preview.exitCode == 0 && preview.stdout.contains("\"applied\": false"))
        #expect(store.read() == .key("synthetic-secret"))
        let cleared = try await JevCLIExecution.run(
            .init(arguments: ["key", "clear", "--yes", "--json"]), engine: engine)
        #expect(cleared.exitCode == 0 && store.read() == .missing)
        #expect(JevCLIEnvironment.owner == nil && JevCLIEnvironment.stdin.isEmpty)
    }
    @Test func originalHelpUsageAndMissingKeyFailuresKeepOutputStreams() async throws {
        let engine = JevEngine(store: MemoryJevKeyStore())
        for arguments in [["--help"], ["key", "--help"], ["ask", "--help"]] {
            let reply = try await JevCLIExecution.run(.init(arguments: arguments), engine: engine)
            #expect(reply.exitCode == 0 && reply.stderr.isEmpty && reply.stdout.contains("USAGE:"))
        }
        for (arguments, stdin) in [
            (["key", "set"], Data()), (["ask"], Data("invalid".utf8)), (["key", "bad"], Data()),
        ] {
            let reply = try await JevCLIExecution.run(
                .init(arguments: arguments), engine: engine, stdin: stdin)
            #expect(reply.exitCode == 2 && reply.stdout.isEmpty && !reply.stderr.isEmpty)
        }
        let request = try JSONEncoder().encode(
            JevRequest(state: .text("synthetic"), questions: ["score": .noul("Is this synthetic?")])
        )
        let denied = try await JevCLIExecution.run(
            .init(arguments: ["ask", "--json"]), engine: engine, stdin: request)
        #expect(denied.exitCode == 4 && denied.stdout.isEmpty && denied.stderr.contains("hint:"))
    }
    @Test func originalSettingsPaneModelUsesCheckedEngineAndStopCancelsLocalState() async throws {
        let store = MemoryJevKeyStore()
        let commands = JevCommands(engine: JevEngine(store: store))
        let bridge = Bridge(commands: commands)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let model = JevSettingsModel(engineClient: client)
        model.load(probe: false)
        try await wait { model.status != nil }
        #expect(model.status?.state == .notConfigured && bridge.operations == ["jev.status"])
        model.draft = "synthetic-key"
        model.save()
        try await wait { model.status?.hasSavedKey == true }
        #expect(store.read() == .key("synthetic-key") && model.draft.isEmpty)
        model.remove()
        try await wait { model.status?.state == .notConfigured }
        #expect(store.read() == .missing)
        model.shutdown(); client.invalidate(); await commands.shutdownAndWait()
        model.draft = "later"; model.save()
        #expect(store.read() == .missing && !model.loading.isRunning)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExtensionEngineError.timedOut }
            await Task.yield()
        }
    }
    private final class Bridge: NSObject {
        let commands: JevCommands
        var operations: [String] = []
        init(commands: JevCommands) { self.commands = commands }
        @MainActor @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            operations.append(request.operation)
            commands.invoke([
                "token": request.token.uuidString, "command": request.operation,
                "payload": request.payload,
            ]) { bytes, error in
                let reply = ExtensionEngineReply(
                    token: request.token, ok: error == nil && bytes != nil,
                    payload: bytes as Data? ?? Data("{}".utf8))
                completion((try? ExtensionEngineWire.encode(reply)) ?? Data())
            }
        }
        @MainActor @objc func cancel(_ token: String) { commands.cancel(token) }
    }
}
