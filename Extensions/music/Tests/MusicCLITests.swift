import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite(.serialized) struct MusicCLITests {
        @Test func originalCommandsReceiveTheCompleteHostCLIContext() async throws {
            let request = try ExtensionCLIRequest(
                arguments: ["status", "--player", "builtin", "--json"],
                standardInput: Data("mock-input".utf8),
                workingDirectory: "/tmp/mock-music-context", interactive: true)
            var observed: ExtensionCLIRequest?
            let reply = try await MusicCLIExecution.run(
                request,
                read: {
                    observed = ExtensionCLIContext.request
                    return PlayerSnapshot(player: .builtin, isRunning: true)
                }, send: { _ in }, refresh: {}, renamed: { _, _ in })
            #expect(reply.exitCode == 0)
            #expect(observed?.workingDirectory == request.workingDirectory)
            #expect(observed?.arguments == request.arguments)
            #expect(observed?.standardInput == request.standardInput)
            #expect(observed?.interactive == request.interactive)
            #expect(ExtensionCLIContext.request == nil)
        }

        private func run(
            _ arguments: [String], send: @escaping (MusicTransportRequest) -> Void = { _ in }
        ) async throws -> ExtensionCLIReply {
            try await MusicCLIExecution.run(
                ExtensionCLIRequest(arguments: arguments),
                read: {
                    PlayerSnapshot(
                        player: .builtin, isRunning: true, isPlaying: true, title: "Mock Garden",
                        elapsedSeconds: 12, durationSeconds: 90, volume: 0.5,
                        trackPath: "Mock Garden.wav")
                },
                send: send, refresh: {}, renamed: { _, _ in })
        }

        @Test func originalCommandTreeAndAliasesRemainAvailable() async throws {
            let reply = try await run(["--help"])
            #expect(reply.exitCode == 0)
            for command in [
                "status", "play", "pause", "stop", "toggle", "next", "previous", "volume",
                "players", "open-current", "reveal-current", "library", "ls", "mkdir", "mv",
                "rename", "rm", "start", "seek", "shuffle", "repeat", "rescan", "favorite",
                "unfavorite", "reveal", "open",
            ] {
                #expect(reply.stdout.contains(command))
            }
            let alias = try await run(["playpause", "--player", "builtin", "--json"])
            #expect(alias.exitCode == 0)
            #expect(alias.stdout.contains("toggled"))
        }

        @Test func statusAndTransportUseOwnedPlaybackWithoutNotifications() async throws {
            var sent: [MusicTransportRequest] = []
            let status = try await run(["status", "--player", "builtin", "--json"])
            #expect(status.exitCode == 0)
            #expect(status.stderr.isEmpty)
            #expect(status.stdout.contains("Mock Garden"))
            #expect(status.stdout.contains("elapsedSeconds"))
            for (arguments, request) in [
                (["pause", "--player", "builtin"], MusicTransportRequest.pause),
                (["stop", "--player", "builtin"], .stop),
                (["seek", "0.5"], .seek(0.5)),
                (["volume", "0.25", "--player", "builtin"], .volume(0.25)),
            ] {
                let reply = try await run(arguments, send: { sent.append($0) })
                #expect(reply.exitCode == 0)
                #expect(sent.last == request)
            }
            let invalid = try await run(["seek", "2"], send: { sent.append($0) })
            #expect(invalid.exitCode == 2)
            #expect(invalid.stdout.isEmpty)
            #expect(invalid.stderr.contains("position"))
            #expect(sent.count == 4)
        }

        @Test func libraryCommandsOperateOnSyntheticFilesAndRemovalRequiresYes() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "music-cli-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = SharedDefaults.store
            let prior = defaults.object(forKey: MusicStorage.musicFolderPathKey)
            let confirmation = defaults.object(forKey: "musicFolderExternalConfirmation")
            defer {
                defaults.set(prior, forKey: MusicStorage.musicFolderPathKey)
                defaults.set(confirmation, forKey: "musicFolderExternalConfirmation")
                TrackMeta.invalidateCaches()
            }
            MusicStorage.setMusicDirectory(root)
            try Data().write(to: root.appendingPathComponent("Mock Garden.wav"))
            TrackMeta.invalidateCaches()
            #expect(try await run(["mkdir", "Mock Collection", "--json"]).exitCode == 0)
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Mock Collection").path))
            let listing = try await run(["ls", "--json"])
            #expect(listing.stdout.contains("Mock Garden.wav"))
            #expect(
                try await run(["rename", "Mock Garden.wav", "Mock Waves", "--json"]).exitCode == 0)
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Mock Waves.wav").path))
            let preview = try await run(["rm", "Mock Waves.wav", "--json"])
            #expect(preview.exitCode == 0)
            #expect(preview.stdout.contains("false"))
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Mock Waves.wav").path))
        }
        @Test func cancelledCLIReadDoesNotReturnLateOutput() async throws {
            var continuation: CheckedContinuation<PlayerSnapshot, Never>?
            let command = Task {
                try await MusicCLIExecution.run(
                    ExtensionCLIRequest(arguments: ["status", "--player", "builtin", "--json"]),
                    read: { await withCheckedContinuation { continuation = $0 } },
                    send: { _ in }, refresh: {}, renamed: { _, _ in })
            }
            for _ in 0..<20 where continuation == nil { await Task.yield() }
            #expect(continuation != nil)
            command.cancel()
            continuation?.resume(
                returning: PlayerSnapshot(player: .builtin, isRunning: true, title: "Mock Late"))
            await #expect(throws: CancellationError.self) { try await command.value }
            #expect(!MusicCLIEnvironment.available)
        }

    }
}
