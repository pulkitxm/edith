import EdithExtensionSupport
import Foundation
import Testing
@testable import TimeLapseExtension

@Suite(.serialized) @MainActor struct TimeLapseRemoteUITests {
    @Test func originalRecorderStateKeepsUnsavedDraftAndUIShutdownDoesNotStopEngineRecording()
        async throws
    {
        guard #available(macOS 15.0, *) else { return }
        let owner = TimeLapseRecorder()
        owner.settings.frameRate = 30; owner.selectedDisplays = [42]
        let commands = TimeLapseUICommands(recorder: owner)
        let bridge = Bridge(commands: commands)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let remote = TimeLapseRecorder(engineClient: client)
        await remote.refreshRemote()
        #expect(remote.settings.frameRate == 30 && remote.selectedDisplays == [42])
        remote.settings.frameRate = 60
        await remote.refreshRemote()
        #expect(remote.settings.frameRate == 60 && owner.settings.frameRate == 30)
        owner.recording = true
        await remote.refreshRemote()
        #expect(remote.recording && remote.settings.frameRate == 30)
        await remote.shutdown(); client.invalidate()
        #expect(
            owner.recording && !bridge.operations.contains("recording.ui.stop")
                && !bridge.operations.contains("recording.ui.start"))
        await commands.shutdownAndWait()
        owner.recording = false; await owner.shutdown()
    }
    @available(macOS 15.0, *) @MainActor private final class Bridge: NSObject {
        let commands: TimeLapseUICommands
        let registry = ExtensionCommandRegistry()
        var operations: [String] = []
        init(commands: TimeLapseUICommands) { self.commands = commands }
        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            operations.append(request.operation)
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
                }, execute: { [commands] in try await commands.execute($0, payload: $1) })
        }
        @objc func cancel(_ token: String) { registry.cancel(token) }
    }
}
