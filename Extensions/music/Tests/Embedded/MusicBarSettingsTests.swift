import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicEmbeddedUI
@testable import MusicExtension

@MainActor @Suite(.serialized) struct MusicBarSettingsTests {
    private func reply(collapsed: Bool = false, autoHide: Bool = false, version: String = "1.2.3")
        throws -> Data
    {
        try JSONEncoder().encode(
            EmbeddedMusicUISettings(
                version: version,
                preferences: .init(barCollapsed: collapsed, barAutoHide: autoHide)))
    }

    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 where !predicate() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func originalBindingsUseRealEnginePreferencesAndChangeActualBarSlots() async throws {
        let defaults = SharedDefaults.store
        let keys = [
            AppStorageKeys.Music.barCollapsed, AppStorageKeys.Music.barAutoHide,
            MusicFade.enabledKey, MusicFade.secondsKey, "musicSelectedProvider",
        ]
        let prior = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) } }
        defaults.set("local", forKey: "musicSelectedProvider")
        defaults.set(false, forKey: AppStorageKeys.Music.barCollapsed)
        defaults.set(false, forKey: AppStorageKeys.Music.barAutoHide)
        let accounts = MusicAccounts(
            defaults: defaults,
            spotify: MusicSpotifySession(libraryURL: nil, defaults: defaults), pauseLocal: {})
        let worker = try MusicWorker(
            admission: { nil }, makeLiveResources: { .live(accounts: accounts) },
            startImmediately: false)
        let service = MusicUIService(worker: worker, version: "1.2.3", invalidateHostSlots: {})
        let model = EmbeddedMusicSettingsModel(expectedVersion: "1.2.3", invoke: service.execute)
        defer { model.stop(); service.stop(); worker.stop() }
        await model.refresh()
        #expect(model.loaded)
        let collapsed = model.boolean(.barCollapsed, \.barCollapsed)
        let autoHide = model.boolean(.barAutoHide, \.barAutoHide)
        collapsed.wrappedValue = true
        try await settle { model.preferences.barCollapsed }
        #expect(defaults.bool(forKey: AppStorageKeys.Music.barCollapsed))
        let sidebar = try JSONDecoder().decode(
            MusicHostSlots.self,
            from: await service.execute("music.ui.hostSlots", payload: Data("{}".utf8)))
        #expect(sidebar.sidebar && !sidebar.footer)
        autoHide.wrappedValue = true
        try await settle { model.preferences.barAutoHide }
        let hidden = try JSONDecoder().decode(
            MusicHostSlots.self,
            from: await service.execute("music.ui.hostSlots", payload: Data("{}".utf8)))
        #expect(!hidden.sidebar && !hidden.footer)
        #expect(accounts.playerReady)
        autoHide.wrappedValue = false; collapsed.wrappedValue = false
        try await settle { !model.preferences.barAutoHide && !model.preferences.barCollapsed }
        let footer = try JSONDecoder().decode(
            MusicHostSlots.self,
            from: await service.execute("music.ui.hostSlots", payload: Data("{}".utf8)))
        #expect(footer.footer && !footer.sidebar)
        model.fadeLength.wrappedValue = 100
        try await settle { model.preferences.fadeLength == 8 }
        #expect(defaults.double(forKey: MusicFade.secondsKey) == 8)
        model.boolean(.crossfade, \.crossfade).wrappedValue = false
        try await settle { !model.preferences.crossfade }
        #expect(!defaults.bool(forKey: MusicFade.enabledKey))
        model.set(.barCollapsed, value: 0.5)
        model.set(.playPause, value: 1)
        #expect(!model.preferences.barCollapsed)
        service.stop()
        collapsed.wrappedValue = true
        try await settle { model.error != nil }
        #expect(!model.preferences.barCollapsed)
        #expect(!collapsed.wrappedValue)
        #expect(!defaults.bool(forKey: AppStorageKeys.Music.barCollapsed))
    }

    @Test func newerReadsRejectStaleStateAndBoundedVersionChecksRejectInvalidReplies()
        async throws
    {
        let valid = try reply(collapsed: true)
        let old = try reply()
        var pending: [CheckedContinuation<Data, Error>] = []
        let model = EmbeddedMusicSettingsModel(expectedVersion: "1.2.3") { operation, payload in
            #expect(operation == "music.ui.settings")
            #expect(payload == Data("{}".utf8))
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        let first = Task { await model.refresh() }
        try await settle { pending.count == 1 }
        let second = Task { await model.refresh() }
        try await settle { pending.count == 2 }
        pending[1].resume(returning: valid); await second.value
        pending[0].resume(returning: old); await first.value
        #expect(model.preferences.barCollapsed)
        model.stop()
        for data in [try reply(version: "stale"), Data(count: 4097), Data("{}".utf8)] {
            let rejected = EmbeddedMusicSettingsModel(expectedVersion: "1.2.3") { _, _ in data }
            await rejected.refresh()
            #expect(!rejected.loaded)
            #expect(rejected.error != nil)
            rejected.stop()
        }
        var invalid = EmbeddedMusicUISettings(version: "1.2.3", preferences: .init())
        invalid.preferences.fadeLength = 100
        #expect(throws: (any Error).self) { try invalid.validate(expectedVersion: "1.2.3") }
    }

    @Test func preferenceWritesStayOrderedCoalesceAndCannotApplyAfterClose() async throws {
        var settings = EmbeddedMusicUISettings(version: "1.2.3", preferences: .init())
        var actions: [EmbeddedMusicUIAction] = []
        var pending: CheckedContinuation<Data, Error>?
        let model = EmbeddedMusicSettingsModel(expectedVersion: "1.2.3") { operation, payload in
            if operation == "music.ui.settings" { return try JSONEncoder().encode(settings) }
            #expect(operation == "music.ui.action")
            let action = try JSONDecoder().decode(EmbeddedMusicUIAction.self, from: payload)
            actions.append(action)
            if actions.count == 1 {
                _ = try await withCheckedThrowingContinuation { pending = $0 }
            }
            if action.kind == .barCollapsed {
                settings.preferences.barCollapsed = action.value == 1
            }
            if action.kind == .barAutoHide { settings.preferences.barAutoHide = action.value == 1 }
            return Data("{}".utf8)
        }
        await model.refresh()
        model.boolean(.barCollapsed, \.barCollapsed).wrappedValue = true
        try await settle { pending != nil }
        for value in [true, false, true, false] {
            model.boolean(.barAutoHide, \.barAutoHide).wrappedValue = value
        }
        pending?.resume(returning: Data("{}".utf8)); pending = nil
        try await settle { actions.count == 2 && model.preferences.barCollapsed }
        #expect(actions.map(\.kind) == [.barCollapsed, .barAutoHide])
        #expect(actions.last?.value == 0)
        #expect(!model.preferences.barAutoHide)
        model.stop()
        model.boolean(.barCollapsed, \.barCollapsed).wrappedValue = true
        await Task.yield()
        #expect(actions.count == 2)
        #expect(!model.loaded)
        #expect(model.closed)

        var late: CheckedContinuation<Data, Error>?
        let delayed = EmbeddedMusicSettingsModel(expectedVersion: "1.2.3") { operation, _ in
            if operation == "music.ui.settings" { return try self.reply() }
            return try await withCheckedThrowingContinuation { late = $0 }
        }
        await delayed.refresh()
        delayed.boolean(.barCollapsed, \.barCollapsed).wrappedValue = true
        try await settle { late != nil }
        delayed.stop()
        late?.resume(returning: Data("{}".utf8))
        for _ in 0..<20 { await Task.yield() }
        #expect(delayed.closed && !delayed.loaded)
        #expect(!delayed.preferences.barCollapsed)
    }

    @Test func settingsPresentationReleaseCancelsItsExactClientAndRejectsLateReply() async throws {
        let bridge = MusicSettingsTestBridge()
        let id = UUID()
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: id))
        let scene = try #require(
            MusicEmbeddedPresentation(
                context: ["location": "settings", "section": "music"], client: client,
                uiOnly: false, version: "1.2.3"))
        let runtime = MusicEmbeddedRuntime()
        #expect(runtime.install(scene, id: id))
        let controller = try #require(
            runtime.view([
                "location": "settings", "section": "music", "presentationID": id.uuidString,
            ]))
        #expect(controller.view.window == nil)
        let model = try #require(scene.settingsModel)
        let read = Task { await model.refresh() }
        try await settle { bridge.request != nil }
        let request = try #require(bridge.request)
        #expect(request.presentationID == id)
        #expect(request.operation == "music.ui.settings")
        #expect(runtime.release(["presentationID": id.uuidString]))
        await read.value
        #expect(bridge.cancelled.contains(request.token.uuidString))
        bridge.complete(try reply(collapsed: true))
        for _ in 0..<20 { await Task.yield() }
        #expect(model.closed && !model.loaded && !model.preferences.barCollapsed)
        #expect(runtime.presentationCount == 0)
        runtime.stop()
    }

    @Test func originalSettingsControlsRenderUnshownAtBothWidthsThemesAndZoom() async throws {
        let model = EmbeddedMusicSettingsModel(expectedVersion: "1.2.3") { _, _ in
            try self.reply(collapsed: true, autoHide: true)
        }
        await model.refresh()
        let defaults = SharedDefaults.store
        let priorZoom = defaults.object(forKey: WindowZoom.defaultsKey)
        defer {
            model.stop(); defaults.set(priorZoom, forKey: WindowZoom.defaultsKey); UIScale.apply(1)
        }
        let root = URL(
            fileURLWithPath: "/tmp/extension-final-batch-20261010/music-bar-settings-render")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for width in [540.0, 960.0] {
            for scheme in [ColorScheme.light, .dark] {
                for zoom in [1.0, 1.5] {
                    defaults.set(zoom, forKey: WindowZoom.defaultsKey); UIScale.apply(zoom)
                    let controller = NSHostingController(
                        rootView: ExtensionPresentationState(
                            compact: width < 720, visible: false, availableWidth: width,
                            intrinsic: false
                        ).withContext {
                            ExtensionPageHost { EmbeddedMusicSettings(model: model) }
                        })
                    controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1000 * zoom)
                    controller.view.appearance = NSAppearance(
                        named: scheme == .dark ? .darkAqua : .aqua)
                    let container = MusicSettingsRenderView(frame: controller.view.frame)
                    container.color =
                        scheme == .dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
                    container.addSubview(controller.view)
                    controller.view.autoresizingMask = [.width, .height]
                    try await Task.sleep(for: .milliseconds(100))
                    controller.view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(
                        container.bitmapImageRepForCachingDisplay(in: container.bounds))
                    container.cacheDisplay(in: container.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(png.count > 1000)
                    let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")-\(zoom)"
                    try png.write(to: root.appendingPathComponent(suffix + ".png"))
                    #expect(controller.view.window == nil)
                    #expect(model.preferences.barCollapsed && model.preferences.barAutoHide)
                    controller.view.removeFromSuperview()
                }
            }
        }
    }
}

@MainActor private final class MusicSettingsTestBridge: NSObject {
    var request: ExtensionEngineRequest?
    var cancelled: [String] = []
    private var completion: ((NSData) -> Void)?

    @objc func invoke(_ data: NSData, completion: @escaping (NSData) -> Void) {
        request = try? ExtensionEngineWire.decode(ExtensionEngineRequest.self, from: data as Data)
        self.completion = completion
    }

    @objc func cancel(_ token: NSString) { cancelled.append(token as String) }

    func complete(_ payload: Data) {
        guard let request,
            let data = try? ExtensionEngineWire.encode(
                ExtensionEngineReply(token: request.token, ok: true, payload: payload))
        else { return }
        completion?(data as NSData); completion = nil
    }
}

private final class MusicSettingsRenderView: NSView {
    var color = NSColor.white
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
