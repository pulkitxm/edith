import Foundation
import Testing

@testable import MusicExtension

@MainActor @Suite(.serialized) struct MusicExternalEffectTests {
    @Test func inertExternalPlayerNeverSubscribesRunsScriptsOrPublishesState() async {
        var calls = 0
        let effects = ExternalMusicEffects(
            isInert: true,
            observeExternal: { _, _ in
                calls += 1; return NSObject()
            },
            removeExternal: { _ in calls += 1 },
            observeCommand: { _ in
                calls += 1; return NSObject()
            },
            observeState: { _ in
                calls += 1; return NSObject()
            },
            removeLocal: { _ in calls += 1 },
            isRunning: { _ in
                calls += 1; return true
            },
            readPlayback: { _, _ in
                calls += 1; return nil
            }, postState: { _ in calls += 1 })
        for external in [ExternalMusic(effects: effects), ExternalMusic(effects: .inert)] {
            external.start(); external.start()
            external.observePlayback(true)
            external.handle(command: ["action": "playPause"])
            external.perform(.toggle); external.retryPlayback()
            await external.refreshPresentationPlayback(force: true)
            external.broadcast(); external.stop(); external.stop()
            #expect(external.systemResourceCount == 0)
            #expect(external.current == nil)
            #expect(external.playback == nil)
            #expect(external.lastError == nil)
        }
        #expect(calls == 0)
    }

    @Test func liveInjectedEffectsPreserveOriginalNotificationAndCommandBehavior() async throws {
        var callbacks: [String: @MainActor ([AnyHashable: Any]) -> Void] = [:]
        var command: (@MainActor ([AnyHashable: Any]) -> Void)?
        var state: (@MainActor () -> Void)?
        var removed = 0
        var scripts: [(ExternalApp, String?)] = []
        var posts: [[String: Any]] = []
        let effects = ExternalMusicEffects(
            isInert: false,
            observeExternal: { app, receive in
                callbacks[app.rawValue] = receive; return NSObject()
            },
            removeExternal: { _ in removed += 1 },
            observeCommand: {
                command = $0; return NSObject()
            },
            observeState: {
                state = $0; return NSObject()
            }, removeLocal: { _ in removed += 1 },
            isRunning: { _ in true },
            readPlayback: { app, source in
                scripts.append((app, source))
                return ExternalPlayback(
                    track: .init(
                        app: app, title: "Mock Garden", artist: "Mock Artist", isPlaying: false,
                        duration: 100),
                    position: 25, volume: 0.5, shuffling: false, repeating: false,
                    canShuffle: true, canRepeat: true)
            },
            postState: { posts.append($0) })
        let external = ExternalMusic(effects: effects)
        defer { external.stop() }
        external.start(); external.start()
        #expect(external.systemResourceCount == 4)
        #expect(Set(callbacks.keys) == Set(["spotify", "music"]))
        callbacks["spotify"]?([
            "Name": "Mock Garden", "Artist": "Mock Artist", "Player State": "Playing",
            "Duration": 100_000,
        ])
        #expect(external.current?.app == .spotify)
        #expect(external.current?.duration == 100)
        command?(["action": "pause"])
        for _ in 0..<50 where scripts.isEmpty { await Task.yield() }
        #expect(scripts.first?.0 == .spotify)
        #expect(scripts.first?.1 == "pause")
        #expect(external.playback?.position == 25)
        #expect(external.current?.isPlaying == false)
        state?()
        #expect(posts.last?["title"] as? String == "Mock Garden")
        callbacks["music"]?([
            "Name": "Mock Meadow", "Artist": "Mock Artist", "Player State": "Playing",
            "Total Time": 80_000,
        ])
        #expect(external.current?.app == .music)
        #expect(external.current?.duration == 80)
        #expect(external.playback == nil)
        external.stop()
        #expect(removed == 4)
        #expect(external.systemResourceCount == 0)
    }

    @Test func stopRejectsLatePlaybackAndCancelsObservationOwnership() async throws {
        var receive: (@MainActor ([AnyHashable: Any]) -> Void)?
        var pending: CheckedContinuation<ExternalPlayback?, Error>?
        var posts = 0
        let effects = ExternalMusicEffects(
            isInert: false,
            observeExternal: { app, handler in
                if app == .spotify { receive = handler }; return NSObject()
            },
            removeExternal: { _ in }, observeCommand: { _ in NSObject() },
            observeState: { _ in NSObject() }, removeLocal: { _ in }, isRunning: { _ in true },
            readPlayback: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } },
            postState: { _ in posts += 1 })
        let external = ExternalMusic(effects: effects)
        external.start()
        receive?(["Name": "Mock Garden", "Player State": "Playing", "Duration": 100_000])
        let read = Task { await external.refreshPresentationPlayback(force: true) }
        for _ in 0..<50 where pending == nil { await Task.yield() }
        #expect(pending != nil)
        external.stop()
        pending?.resume(
            returning: .init(
                track: .init(
                    app: .spotify, title: "Mock Late", artist: "", isPlaying: true, duration: 100),
                position: 25, volume: 0.5, shuffling: false, repeating: false, canShuffle: true,
                canRepeat: true))
        await read.value
        #expect(external.current == nil)
        #expect(external.playback == nil)
        #expect(posts == 0)
        #expect(external.systemResourceCount == 0)
    }
}
