import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicEmbeddedUI
@testable import MusicExtension

@MainActor @Suite(.serialized) struct MusicNotchTests {
    private func context(
        _ section: EmbeddedMusicNotchRoute.Section, tile: SurfaceTile = SurfaceTile(.music)
    ) throws -> NSDictionary {
        [
            "location": "notch", "section": section.rawValue, "target": "notch",
            "tile": try JSONEncoder().encode(tile),
        ]
    }

    private func engine(
        states: @escaping @MainActor () -> [MusicSurfacePlayback],
        commands: @escaping @MainActor (MusicSurfaceCommand) -> Void = { _ in },
        hidden: @escaping @MainActor () -> Bool = { false },
        icon: SurfaceThumbnail? = nil
    ) -> MusicSurface {
        MusicSurface(
            read: { _ in states() }, perform: { commands($0) }, appIcon: { _ in icon },
            privacyValues: {
                ["active": hidden() ? "1" : "0", "blurMusic": "1"]
            })
    }

    private func playback(_ source: String = "local", playing: Bool = true) -> MusicSurfacePlayback
    {
        .init(
            sourceID: source, sourceTitle: source == "local" ? "Local library" : "Mock player",
            trackKey: "Mock Collection/Mock.mov", title: "Mock Garden", artist: "Mock Artist",
            playing: playing, elapsed: 25, duration: 100, volume: 0.6, shuffle: false,
            repeating: true)
    }

    private func fixtureIcon() throws -> SurfaceThumbnail {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rectangle in
            NSColor.systemGreen.setFill(); rectangle.fill()
            NSColor.systemBlue.setFill(); CGRect(x: 8, y: 8, width: 16, height: 16).fill()
            return true
        }
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        return SurfaceThumbnail(
            data: try #require(bitmap.representation(using: .png, properties: [:])),
            accessibilityLabel: "Mock player icon")
    }

    @Test func exactNotchRoutesValidateTargetTileAndNormalizedConfiguration() throws {
        for section in EmbeddedMusicNotchRoute.Section.allCases {
            let route = try #require(EmbeddedMusicNotchRoute(context: context(section)))
            #expect(route.section == section)
            #expect(route.request.target == .notch)
            let invalid = try context(section).mutableCopy() as! NSMutableDictionary
            invalid["target"] = "home"
            #expect(EmbeddedMusicNotchRoute(context: invalid) == nil)
            invalid["target"] = "notch";
            invalid["tile"] = try JSONEncoder().encode(SurfaceTile(.calendar))
            #expect(EmbeddedMusicNotchRoute(context: invalid) == nil)
        }
        var hidden = SurfaceTile(.music); hidden.hidden = true
        #expect(try EmbeddedMusicNotchRoute(context: context(.card, tile: hidden)) == nil)
        let wrong = try context(.card).mutableCopy() as! NSMutableDictionary
        wrong["section"] = "music.generic"
        #expect(EmbeddedMusicNotchRoute(context: wrong) == nil)
        wrong["section"] = "music"; wrong["tile"] = Data(count: 65_537)
        #expect(EmbeddedMusicNotchRoute(context: wrong) == nil)
    }

    @Test func originalCardControlsConsumeActualCheckedEngineSnapshotAndCurrentIdentity()
        async throws
    {
        var current = playback()
        var commands: [MusicSurfaceCommand] = []
        let service = engine(states: { [current] }, commands: { commands.append($0) })
        let route = try #require(EmbeddedMusicNotchRoute(context: context(.card)))
        let model = EmbeddedMusicNotchModel(request: route.request, invoke: service.execute)
        await model.refresh()
        #expect(model.nowPlaying?.title == "Mock Garden")
        #expect(model.nowPlaying?.source == .local)
        #expect(model.nowPlayingDuration == 100)
        #expect(model.nowPlayingProgress() == 0.25)
        #expect(model.nowPlayingVolume == 0.6)
        #expect(model.nowPlayingShuffle == false)
        #expect(model.nowPlayingRepeat == true)
        model.nowPlayingSeek(0.5)
        for _ in 0..<50 where commands.isEmpty { await Task.yield() }
        #expect(commands.first?.action == "seek")
        #expect(commands.first?.trackKey == current.trackKey)
        #expect(commands.first?.value == 0.5)
        current.trackKey = "Mock Changed.mov"
        model.nowPlayingPlayPause()
        for _ in 0..<50 where model.nowPlayingControlError == nil { await Task.yield() }
        #expect(commands.count == 1)
        #expect(model.nowPlayingControlError != nil)
        for _ in 0..<50 where model.row?.id != "local:" + current.token {
            await model.refresh(); await Task.yield()
        }
        #expect(model.row?.id == "local:" + current.token)
        #expect(
            model.state?.snapshot.actions.contains { $0.id == current.identifier("openPlayer") }
                == true)
        model.openNowPlayingApp()
        for _ in 0..<50 where commands.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(commands.last?.action == "openPlayer")
        model.shutdown()
        #expect(model.closed)
        #expect(model.nowPlaying == nil)
    }

    @Test func pausedSelectionPrivacyAndTileActionsMatchOriginalNotchOwnership() async throws {
        var values = [playback(), playback("external.music", playing: false)]
        var hidden = false
        var count = 0
        let service = engine(states: { values }, commands: { _ in count += 1 }, hidden: { hidden })
        let route = try #require(EmbeddedMusicNotchRoute(context: context(.card)))
        let model = EmbeddedMusicNotchModel(request: route.request, invoke: service.execute)
        await model.refresh(); #expect(model.nowPlaying?.source == .local)
        values[0].playing = false
        await model.refresh(); #expect(model.nowPlaying?.source == .local)
        values[1].playing = true
        await model.refresh(); #expect(model.nowPlaying?.source == .external("Mock player"))
        values[1].playing = false
        await model.refresh(); #expect(model.nowPlaying?.source == .external("Mock player"))
        hidden = true
        await model.refresh()
        #expect(model.hidden)
        #expect(model.nowPlaying == nil)
        model.nowPlayingPlayPause()
        await Task.yield(); #expect(count == 0)
        var tile = SurfaceTile(.music); tile.showActions = false;
        tile.hiddenFields = ["progress", "artist", "artwork", "shuffle", "repeat"]
        hidden = false
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let state = try MusicNotchState.decode(
            await service.execute(
                "music.notch.snapshot", payload: request.encoded(providerID: "music")))
        #expect(state.snapshot.controlActions.isEmpty)
        #expect(
            state.playback.allSatisfy {
                $0.duration == 0 && $0.elapsed == 0 && $0.shuffle == nil && $0.repeating == nil
            })
        #expect(state.snapshot.rows.allSatisfy { $0.detail.isEmpty && $0.thumbnail == nil })
        model.shutdown()
    }

    @Test func lateReadCancellationAndDisableCannotReviveNativeNotchState() async throws {
        let route = try #require(EmbeddedMusicNotchRoute(context: context(.card)))
        let service = engine(states: { [playback()] })
        let encoded = try await service.execute(
            "music.notch.snapshot", payload: route.request.encoded(providerID: "music"))
        var pending: CheckedContinuation<Data, Error>?
        let model = EmbeddedMusicNotchModel(
            request: route.request,
            invoke: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } })
        let read = Task { await model.refresh() }
        for _ in 0..<50 where pending == nil { await Task.yield() }
        #expect(pending != nil)
        model.shutdown(); pending?.resume(returning: encoded)
        await read.value
        #expect(model.closed && model.state == nil)
        #expect(model.nowPlayingControlError == nil)
        var invalid = try EmbeddedMusicNotchState.decode(encoded)
        invalid.playback[0].duration = .infinity
        #expect(throws: (any Error).self) { try invalid.encoded() }
    }

    @Test func originalNativeNotchBodiesRenderUnshownAndStopAtSixteenPresentations() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let bridge = MusicNotchReadonlyBridge()
        let runtime = MusicEmbeddedRuntime()
        var controllers: [NSViewController] = []
        let icon = try fixtureIcon()
        var current = playback("external.music")
        current.thumbnail = icon
        let service = engine(states: { [current] }, icon: icon)
        for section in EmbeddedMusicNotchRoute.Section.allCases {
            let input = try context(section)
            let route = try #require(EmbeddedMusicNotchRoute(context: input))
            let model = EmbeddedMusicNotchModel(request: route.request, invoke: service.execute)
            await model.refresh()
            for width in [80.0, 360.0] {
                let rendering = ImageRenderer(
                    content: EmbeddedMusicNotchScene(route: route, model: model).environment(
                        \.automaticViewActionsEnabled, false
                    ).frame(width: width, height: section == .card ? 300 : 32).background(.black))
                #expect(rendering.nsImage != nil)
            }
            #expect(model.nowPlayingAppIcon != nil)
            #expect(model.nowPlayingArtwork != nil)
            let controller = NSHostingController(
                rootView: EmbeddedMusicNotchScene(route: route, model: model)
                    .environment(\.automaticViewActionsEnabled, false))
            controller.view.frame = CGRect(
                x: 0, y: 0, width: 360, height: section == .card ? 300 : 32)
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.view.window == nil)
            #expect(controller.view.fittingSize.width.isFinite)
            model.shutdown()
        }
        for index in 0..<16 {
            let section = EmbeddedMusicNotchRoute.Section.allCases[index % 4]
            let id = UUID()
            let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: id))
            let sceneContext = try context(section)
            let scene = try #require(
                MusicEmbeddedPresentation(context: sceneContext, client: client, uiOnly: false))
            #expect(runtime.install(scene, id: id))
            let input = sceneContext.mutableCopy() as! NSMutableDictionary
            input["presentationID"] = id.uuidString
            let controller = try #require(runtime.view(input))
            controller.view.frame = CGRect(x: 0, y: 0, width: 360, height: 300)
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.view.window == nil)
            controllers.append(controller)
            input["section"] = "main"
            #expect(runtime.view(input) == nil)
        }
        #expect(runtime.presentationCount == 16)
        let id = UUID()
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: id))
        let extra = try #require(
            MusicEmbeddedPresentation(context: context(.card), client: client, uiOnly: false))
        #expect(!runtime.install(extra, id: id))
        #expect(runtime.presentationCount == 16)
        runtime.stop()
        #expect(runtime.presentationCount == 0)
        #expect(!runtime.configured)
        #expect(controllers.allSatisfy { $0.view.window == nil })
        controllers.removeAll()
    }
}

@MainActor private final class MusicNotchReadonlyBridge: NSObject {
    @objc(invoke:completion:) func invoke(_ input: NSData, completion: @escaping (NSData) -> Void) {
        guard
            let request = try? ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: input as Data),
            let reply = try? ExtensionEngineWire.encode(
                ExtensionEngineReply(token: request.token, ok: false))
        else { return }
        completion(reply as NSData)
    }
    @objc(cancel:) func cancel(_ token: NSString) {}
}
