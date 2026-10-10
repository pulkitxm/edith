import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite(.serialized) struct MusicUIServiceTests {
        @Test func ownedEngineReadsLibraryAndValidatesActionsAgainstRealFiles() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "music-engine-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = SharedDefaults.store
            let path = defaults.object(forKey: MusicStorage.musicFolderPathKey)
            let confirmation = defaults.object(forKey: "musicFolderExternalConfirmation")
            defer {
                defaults.set(path, forKey: MusicStorage.musicFolderPathKey)
                defaults.set(confirmation, forKey: "musicFolderExternalConfirmation")
                TrackMeta.invalidateCaches()
            }
            MusicStorage.setMusicDirectory(root)
            try Data().write(to: root.appendingPathComponent("Mock Garden.wav"))
            TrackMeta.invalidateCaches()
            let player = LocalMusicPlayer()
            let accounts = MusicAccounts(
                defaults: defaults,
                spotify: MusicSpotifySession(libraryURL: nil, defaults: defaults), pauseLocal: {})
            let worker = MusicWorker(player: player, accounts: accounts, startImmediately: false)
            let service = MusicUIService(worker: worker)
            defer { worker.stop() }
            let bytes = try await service.execute(
                "music.ui.read", payload: JSONEncoder().encode(MusicUIQuery()))
            let state = try JSONDecoder().decode(MusicUIState.self, from: bytes)
            try state.validate()
            #expect(state.root.path == root.resolvingSymlinksInPath().path)
            #expect(state.folderTracks.map(\.path) == ["Mock Garden.wav"])
            _ = try await service.execute(
                "music.ui.action",
                payload: JSONEncoder().encode(
                    MusicUIAction(kind: .createFolder, target: "Mock Collection")))
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Mock Collection").path))
            _ = try await service.execute(
                "music.ui.action",
                payload: JSONEncoder().encode(
                    MusicUIAction(kind: .rename, path: "Mock Garden.wav", target: "Mock Waves")))
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Mock Waves.wav").path))
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "music.ui.action",
                    payload: JSONEncoder().encode(
                        MusicUIAction(kind: .rename, path: "../escape.wav", target: "Mock Unsafe")))
            }
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "music.ui.action",
                    payload: JSONEncoder().encode(MusicUIAction(kind: .seek, value: 2)))
            }
            let replyData = try await service.execute(
                "music.cli",
                payload: JSONEncoder().encode(ExtensionCLIRequest(arguments: ["ls", "--json"])))
            let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: replyData)
            #expect(reply.exitCode == 0)
            #expect(reply.stdout.contains("Mock Waves.wav"))
            _ = try await service.execute(
                "music.ui.action",
                payload: JSONEncoder().encode(MusicUIAction(kind: .crossfade, value: 0)))
            #expect(!defaults.bool(forKey: MusicFade.enabledKey))
            _ = try await service.execute(
                "music.ui.action",
                payload: JSONEncoder().encode(MusicUIAction(kind: .fadeLength, value: 3)))
            #expect(defaults.double(forKey: MusicFade.secondsKey) == 3)
            _ = try await service.execute(
                "music.ui.action",
                payload: JSONEncoder().encode(MusicUIAction(kind: .barCollapsed, value: 1)))
            #expect(defaults.bool(forKey: AppStorageKeys.Music.barCollapsed))
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "music.ui.action",
                    payload: JSONEncoder().encode(MusicUIAction(kind: .fadeLength, value: 15)))
            }
            #expect(defaults.double(forKey: MusicFade.secondsKey) == 3)
            service.stop()
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "music.ui.action",
                    payload: JSONEncoder().encode(
                        MusicUIAction(kind: .createFolder, target: "Mock Disabled")))
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Mock Disabled").path))
        }
    }
}
