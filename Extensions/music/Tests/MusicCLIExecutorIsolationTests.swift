import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite struct MusicCLIExecutorIsolationTests {
        @Test func erasedAsyncWitnessReturnsToMainActorBeforeBuiltinCallbacks() async throws {
            let priorRead = MusicCLIEnvironment.readBuiltin
            let priorSend = MusicCLIEnvironment.sendBuiltin
            let priorAvailable = MusicCLIEnvironment.available
            let defaults = MusicCLIEnvironment.sharedDefaults
            let priorPlayer = defaults.object(forKey: MusicMemory.key)
            defer {
                MusicCLIEnvironment.readBuiltin = priorRead
                MusicCLIEnvironment.sendBuiltin = priorSend
                MusicCLIEnvironment.available = priorAvailable
                defaults.set(priorPlayer, forKey: MusicMemory.key)
            }
            let events = MusicCallbackRecorder<String>()
            MusicCLIEnvironment.readBuiltin = {
                MainActor.preconditionIsolated()
                events.append("read")
                return PlayerSnapshot(player: .builtin, isRunning: true)
            }
            MusicCLIEnvironment.sendBuiltin = { request in
                MainActor.preconditionIsolated()
                #expect(request == .pause)
                events.append("send")
            }
            MusicCLIEnvironment.available = true
            let output = MusicCallbackRecorder<String>()
            try await Task.detached {
                var parsed = try MusicCommand.parseAsRoot(["pause", "--player", "builtin"])
                if var command = parsed as? AsyncParsableCommand {
                    try await ExtensionCLIContext.$outputSink.withValue({ text, error in
                        #expect(!error)
                        output.append(text)
                    }) {
                        try await command.run()
                    }
                } else {
                    Issue.record("Expected an async music command")
                    try parsed.run()
                }
            }.value
            #expect(events.values == ["read", "send"])
            #expect(output.values == ["paused  (Edith)\n"])
        }
    }
}
