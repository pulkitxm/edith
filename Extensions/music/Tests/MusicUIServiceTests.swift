import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite(.serialized) struct MusicUIServiceTests {
        @Test func folderIntentRequiresAcknowledgementAndRejectsLateCompletionAfterStop()
            async throws
        {
            let worker = MusicWorker(startImmediately: false)
            let service = MusicUIService(worker: worker)
            let prior = MusicHostNavigation.navigate
            defer {
                service.stop(); worker.stop(); MusicHostNavigation.navigate = prior
            }
            var pending: CheckedContinuation<Void, Error>?
            MusicHostNavigation.navigate = { _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }
            let navigation = Task { try await MusicHostNavigation.open(path: "Mock Collection") }
            for _ in 0..<50 where pending == nil { await Task.yield() }
            #expect(pending != nil)
            #expect(MusicHostNavigation.folderIntent == nil)
            pending?.resume(); pending = nil
            try await navigation.value
            #expect(MusicHostNavigation.folderIntent == .init(revision: 1, path: "Mock Collection"))
            MusicHostNavigation.navigate = { _ in throw ExtensionPeerError.unavailable }
            await #expect(throws: (any Error).self) {
                try await MusicHostNavigation.open(path: "Mock Rejected")
            }
            #expect(MusicHostNavigation.folderIntent?.path == "Mock Collection")
            MusicHostNavigation.navigate = { _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }
            let late = Task { try await MusicHostNavigation.open(path: "Mock Late") }
            for _ in 0..<50 where pending == nil { await Task.yield() }
            #expect(pending != nil)
            service.stop()
            pending?.resume()
            await #expect(throws: CancellationError.self) { try await late.value }
            #expect(MusicHostNavigation.folderIntent == nil)
        }

        @Test func hostSlotsPreserveOriginalPlaybackAndCollapseGates() async throws {
            let defaults = SharedDefaults.store
            let keys = [
                AppStorageKeys.Music.barAutoHide, AppStorageKeys.Music.barCollapsed,
                "musicSelectedProvider", "musicYoutubeAccountSaved",
            ]
            let prior = keys.map { defaults.object(forKey: $0) }
            defer { for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) } }
            for provider in ["local", "spotify", "youtubeMusic"] {
                for saved in [false, true] where provider == "youtubeMusic" || !saved {
                    defaults.set(provider, forKey: "musicSelectedProvider")
                    defaults.set(saved, forKey: "musicYoutubeAccountSaved")
                    let accounts = MusicAccounts(
                        defaults: defaults,
                        spotify: MusicSpotifySession(libraryURL: nil, defaults: defaults),
                        pauseLocal: {})
                    let worker = MusicWorker(accounts: accounts, startImmediately: false)
                    let service = MusicUIService(worker: worker, version: "1.2.3")
                    for autoHide in [false, true] {
                        for collapsed in [false, true] {
                            defaults.set(autoHide, forKey: AppStorageKeys.Music.barAutoHide)
                            defaults.set(collapsed, forKey: AppStorageKeys.Music.barCollapsed)
                            let bytes = try await service.execute(
                                "music.ui.hostSlots", payload: Data("{}".utf8))
                            let slots = try JSONDecoder().decode(MusicHostSlots.self, from: bytes)
                            let visible = provider == "local" ? !autoHide : saved
                            #expect(slots.version == "1.2.3")
                            #expect(slots.footer == (visible && !collapsed))
                            #expect(slots.sidebar == (visible && collapsed))
                            #expect(!(slots.footer && slots.sidebar))
                            #expect(bytes.count < 256)
                        }
                    }
                    for invalid in [
                        "[]", "{\"path\":\"Mock\"}", String(repeating: " ", count: 257),
                    ] {
                        await #expect(throws: (any Error).self) {
                            try await service.execute(
                                "music.ui.hostSlots", payload: Data(invalid.utf8))
                        }
                    }
                    service.stop()
                    await #expect(throws: (any Error).self) {
                        try await service.execute("music.ui.hostSlots", payload: Data("{}".utf8))
                    }
                    worker.stop()
                }
            }
        }

        @Test func downloadsUseOwnedQueueAndRejectRequestsAfterDisable() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "music-downloads-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("queue.json")
            let queue = DownloadWorker(
                file: file, executable: { nil }, galleryExecutable: { nil }, isEnabled: { true })
            let defaults = SharedDefaults.store
            let worker = MusicWorker(
                player: LocalMusicPlayer(),
                accounts: MusicAccounts(
                    defaults: defaults,
                    spotify: MusicSpotifySession(libraryURL: nil, defaults: defaults),
                    pauseLocal: {}), startImmediately: false)
            defer { worker.stop() }
            let downloader = YoutubeDownloader(
                client: MusicDownloadClient(worker: queue), start: false)
            let service = MusicDownloadsService(
                worker: worker, queue: queue, downloader: downloader)
            let url = URL(string: "https://youtu.be/mock-garden")!
            _ = try await service.execute(
                "music.ui.downloads.action",
                payload: JSONEncoder().encode(
                    MusicDownloadAction(
                        kind: .enqueue, urls: [url], prefix: "Mock", outputDirectory: root)))
            let state = try JSONDecoder().decode(
                MusicDownloadsState.self,
                from: await service.execute("music.ui.downloads.read", payload: Data("{}".utf8)))
            #expect(state.snapshot.queued == 1)
            #expect(state.snapshot.records.first?.url == url)
            #expect(
                try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: file)).count
                    == 1)
            let id = try #require(state.snapshot.records.first?.id)
            _ = try await service.execute(
                "music.ui.downloads.action",
                payload: JSONEncoder().encode(MusicDownloadAction(kind: .cancel, id: id)))
            #expect(await queue.snapshot().records.first?.status == .interrupted("Cancelled"))
            _ = try await service.execute(
                "music.ui.downloads.action",
                payload: JSONEncoder().encode(MusicDownloadAction(kind: .retry, id: id)))
            #expect(await queue.snapshot().queued == 1)
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "music.ui.downloads.action",
                    payload: JSONEncoder().encode(
                        MusicDownloadAction(
                            kind: .enqueue, urls: [URL(fileURLWithPath: "/tmp/mock")],
                            outputDirectory: root)))
            }
            #expect(await queue.snapshot().records.count == 1)
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "music.ui.downloads.thumbnail",
                    payload: JSONEncoder().encode(URL(string: "https://youtu.be/mock-unowned")!))
            }
            service.stop()
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "music.ui.downloads.action",
                    payload: JSONEncoder().encode(MusicDownloadAction(kind: .remove, id: id)))
            }
            #expect(await queue.snapshot().records.count == 1)
            await queue.stop()
        }

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
            let levelData = try await service.execute("music.ui.level", payload: Data("{}".utf8))
            #expect(
                try JSONDecoder().decode(Double.self, from: levelData) == PlaybackLevel.shared.level
            )
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
            let priorNavigation = MusicHostNavigation.navigate
            var navigation: [MusicHostNavigationRequest] = []
            MusicHostNavigation.navigate = { navigation.append($0) }
            defer { MusicHostNavigation.navigate = priorNavigation }
            _ = try await service.execute(
                "music.ui.action",
                payload: JSONEncoder().encode(
                    MusicUIAction(kind: .openMusic, path: "Mock Collection")))
            #expect(navigation == [.init(section: "music", path: "Mock Collection")])
            let navigated = try JSONDecoder().decode(
                MusicUIState.self,
                from: await service.execute(
                    "music.ui.read", payload: JSONEncoder().encode(MusicUIQuery())))
            #expect(navigated.folderIntent == .init(revision: 1, path: "Mock Collection"))
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
