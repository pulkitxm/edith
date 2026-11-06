import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI
import Testing

@testable import MusicEmbeddedUI
@testable import MusicExtension

@MainActor @Observable private final class FooterSlotsFixture {
    var footer = false
    var sidebar = false
    var page = "Home"
    var footerHeight: CGFloat = 0
    var reads = 0
    @ObservationIgnored var service: MusicUIService?

    func refresh() async {
        guard let service,
            let data = try? await service.execute("music.ui.hostSlots", payload: Data("{}".utf8)),
            let slots = try? JSONDecoder().decode(MusicHostSlots.self, from: data)
        else { return }
        footer = slots.footer
        sidebar = slots.sidebar
        reads += 1
    }
}

private struct FooterWindowFixture: View {
    let slots: FooterSlotsFixture
    let remote: EmbeddedMusicRemote

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack {
                    Spacer(minLength: 0)
                    if slots.sidebar { EmbeddedMusicSidebarScene(remote: remote) }
                }
                .frame(width: 220)
                Text(slots.page).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if slots.footer {
                EmbeddedMusicFooterScene(remote: remote)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { slots.footerHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { _, height in
                                    slots.footerHeight = height
                                }
                        }
                    }
                    .onDisappear { slots.footerHeight = 0 }
            }
        }
    }
}

@MainActor @Suite(.serialized) struct MusicFooterExpansionTests {
    @Test(arguments: [1.0, 1.6]) func footerCollapsesAndExpandsThroughTheHostSlots(zoom: Double)
        async throws
    {
        try await RenderCapture.exclusiveScale {
            try await RenderCapture.withAccessibility {
                try await exercise(zoom: zoom)
            }
        }
    }

    private func exercise(zoom: Double) async throws {
        let defaults = SharedDefaults.store
        let process = ExtensionScope.process.defaults()
        let keys = [
            AppStorageKeys.Music.barCollapsed, AppStorageKeys.Music.barAutoHide,
            "musicSelectedProvider",
        ]
        let prior = keys.map { defaults.object(forKey: $0) }
        let priorZoom = process.object(forKey: WindowZoom.defaultsKey)
        let priorScale = UIScale.current
        defer {
            for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) }
            process.set(priorZoom, forKey: WindowZoom.defaultsKey)
            UIScale.apply(priorScale)
        }
        process.set(zoom, forKey: WindowZoom.defaultsKey)
        UIScale.apply(zoom)
        defaults.set("local", forKey: "musicSelectedProvider")
        defaults.set(false, forKey: AppStorageKeys.Music.barCollapsed)
        defaults.set(false, forKey: AppStorageKeys.Music.barAutoHide)
        let accounts = MusicAccounts(
            defaults: defaults,
            spotify: MusicSpotifySession(libraryURL: nil, defaults: defaults), pauseLocal: {})
        let worker = try MusicWorker(
            admission: { nil }, makeLiveResources: { .live(accounts: accounts) },
            startImmediately: false)
        let slots = FooterSlotsFixture()
        var invalidations = 0
        let service = MusicUIService(
            worker: worker, version: "1.2.3",
            invalidateHostSlots: {
                invalidations += 1
                Task { @MainActor in await slots.refresh() }
            })
        slots.service = service
        let remote = EmbeddedMusicRemote()
        remote.configure(invoke: { operation, payload in
            try await service.execute(operation, payload: payload)
        })
        defer { remote.stop(); service.stop(); worker.stop() }
        await slots.refresh()
        #expect(slots.footer && !slots.sidebar)

        let size = CGSize(width: 1100, height: 700)
        let host = NSHostingView(
            rootView: ExtensionPageHost { FooterWindowFixture(slots: slots, remote: remote) }
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil })
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))

        let expanded = UIScale.pt(EmbeddedMusicFooter.expandedHeight)
        try await settle(host) { abs(slots.footerHeight - expanded) < 0.5 }
        try expectExpanded(host, slots: slots, height: expanded)

        try press(host, label: "Collapse the player bar")
        try await settle(host) { slots.sidebar && !slots.footer }
        #expect(invalidations == 1)
        #expect(defaults.bool(forKey: AppStorageKeys.Music.barCollapsed))
        #expect(RenderCapture.find(host, label: "Collapse the player bar") == nil)
        #expect(RenderCapture.find(host, label: "Show the player bar") != nil)

        slots.page = "Library"
        try await settle(host) { RenderCapture.find(host, label: "Library") != nil }
        try press(host, label: "Show the player bar")
        try await settle(host) { slots.footer && !slots.sidebar }
        #expect(invalidations == 2)
        #expect(!defaults.bool(forKey: AppStorageKeys.Music.barCollapsed))
        try await settle(host) { abs(slots.footerHeight - expanded) < 0.5 }
        try expectExpanded(host, slots: slots, height: expanded)
        #expect(RenderCapture.find(host, label: "Show the player bar") == nil)

        slots.page = "Calendar"
        try await settle(host) { RenderCapture.find(host, label: "Calendar") != nil }
        try press(host, label: "Collapse the player bar")
        try await settle(host) { slots.sidebar && !slots.footer }
        try press(host, label: "Show the player bar")
        try await settle(host) { slots.footer && abs(slots.footerHeight - expanded) < 0.5 }
        try expectExpanded(host, slots: slots, height: expanded)
        #expect(invalidations == 4)
        if let directory = RenderCapture.directory {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try png.write(
                to: directory.appendingPathComponent("music-footer-expanded-zoom-\(zoom).png"))
        }
    }

    private func expectExpanded(_ host: NSView, slots: FooterSlotsFixture, height: CGFloat) throws {
        #expect(abs(slots.footerHeight - height) < 0.5, "footer \(slots.footerHeight) \(height)")
        let window = try #require(host.window)
        let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
        for label in ["Nothing playing", "Browse music", "Collapse the player bar"] {
            let node = try #require(RenderCapture.find(host, label: label), "\(label)")
            let frame = try #require((node as AnyObject).accessibilityFrame?(), "\(label)")
            #expect(visible.insetBy(dx: -1, dy: -1).contains(frame), "\(label)")
            #expect(frame.minY >= visible.minY - 0.5 && frame.maxY <= visible.minY + height + 0.5)
        }
    }

    private func press(_ host: NSView, label: String) throws {
        let node = try #require(RenderCapture.find(host, label: label), "\(label)")
        #expect((node as AnyObject).accessibilityPerformPress?() == true, "\(label)")
    }

    private func settle(_ host: NSView, until predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() {
            host.window?.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        #expect(predicate())
    }
}
