import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicEmbeddedUI

@MainActor @Suite(.serialized) struct MusicDesignCaptureTests {
    private static let root = URL(fileURLWithPath: "/tmp/mock-music-library")
    private static let trackNames = [
        "Morning Static", "Glass Harbour", "Paper Lanterns", "Northbound", "Slow Orbit",
        "Copper Fields",
    ]

    private enum Library {
        case loading, empty, populated, nothingPlaying, spotify
    }

    private func state(_ library: Library) -> EmbeddedMusicUIState {
        let tracks =
            library == .empty
            ? []
            : Self.trackNames.map {
                EmbeddedMusicUIEntry(
                    path: $0 + ".m4a", url: Self.root.appendingPathComponent($0 + ".m4a"))
            }
        let folders =
            library == .empty
            ? []
            : ["Focus", "Road Trip"].map {
                EmbeddedMusicUIEntry(path: $0, url: Self.root.appendingPathComponent($0))
            }
        return EmbeddedMusicUIState(
            root: Self.root, folders: folders, folderTracks: tracks,
            favourites: Array(tracks.prefix(2)),
            playback: .init(
                path: library == .populated ? tracks.first?.path : nil,
                playing: library == .populated, elapsed: 74, duration: 212, volume: 0.6,
                shuffle: false, repeating: false),
            selected: library == .spotify ? "spotify" : "local",
            spotify: .init(
                connected: false, connecting: false, account: "", title: "", uri: "", artist: "",
                album: "", playing: false, elapsed: 0, duration: 0, volume: 0.7),
            youtubeConnecting: false, youtubeConnected: false, restorePending: 0, events: [],
            cursor: 0, privacy: false)
    }

    private func configure(_ library: Library) async throws {
        let remote = EmbeddedMusicRemote.shared
        remote.stop()
        guard library != .loading else {
            remote.configure { _, _ in
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
            return
        }
        let encoded = try JSONEncoder().encode(state(library))
        remote.configure { operation, _ in
            switch operation {
            case "music.ui.read": return encoded
            case "music.ui.level": return try JSONEncoder().encode(0.4)
            default: return Data("{}".utf8)
            }
        }
        remote.rescan()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !remote.entriesLoaded && ContinuousClock.now < deadline { await Task.yield() }
        try #require(remote.entriesLoaded)
    }

    @Test func pageFooterAndSidebarRenderEveryStateAtBothWidthsThemesAndZoom() async throws {
        let session = MusicCaptureSession()
        defer { session.restore() }
        for library in [Library.loading, .empty, .populated, .spotify] {
            try await configure(library)
            for (width, height) in [(1100.0, 760.0), (640.0, 700.0)] {
                for scheme in [ColorScheme.light, .dark] {
                    let name = "page-\(library)-\(Int(width))-\(scheme)"
                    let view = try await session.render(
                        route: .page, width: width, height: height, scheme: scheme, name: name)
                    #expect(abs(view.bounds.width - width) < 1, Comment(rawValue: name))
                }
            }
        }
        try await configure(.populated)
        session.zoom(1.6)
        _ = try await session.render(
            route: .page, width: 1100, height: 760, scheme: .light, name: "page-populated-zoom")
        session.zoom(1)
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Music.gridView)
        _ = try await session.render(
            route: .page, width: 1100, height: 760, scheme: .dark, name: "page-grid-1100-dark")
        SharedDefaults.store.set(false, forKey: AppStorageKeys.Music.gridView)
    }

    @Test func footerAndSidebarReportTheHeightTheyDraw() async throws {
        let session = MusicCaptureSession()
        defer { session.restore() }
        for library in [Library.populated, .nothingPlaying] {
            try await configure(library)
            for zoom in [1.0, 1.6] {
                session.zoom(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    for width in [1100.0, 640.0] {
                        let name = "footer-\(library)-\(Int(width))-\(scheme)-\(zoom)"
                        let footer = try await session.render(
                            route: .footer, width: width, height: nil, scheme: scheme, name: name)
                        #expect(
                            abs(
                                footer.bounds.height
                                    - UIScale.pt(EmbeddedMusicFooter.expandedHeight))
                                < 1, Comment(rawValue: name))
                    }
                    let name = "sidebar-\(library)-\(scheme)-\(zoom)"
                    let pill = try await session.render(
                        route: .sidebar, width: 232, height: nil, scheme: scheme, name: name)
                    let expected = UIScale.pt(EmbeddedMusicSidebarPill.height)
                    #expect(abs(pill.bounds.height - expected) < 1, Comment(rawValue: name))
                }
            }
        }
        session.zoom(1)
        try await configure(.populated)
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Music.barCollapsed)
        let collapsed = try await session.render(
            route: .footer, width: 1100, height: nil, scheme: .light, name: "footer-collapsed")
        #expect(abs(collapsed.bounds.height - UIScale.pt(EmbeddedMusicFooter.collapsedHeight)) < 1)
        SharedDefaults.store.set(false, forKey: AppStorageKeys.Music.barCollapsed)
    }
}

@MainActor private final class MusicCaptureSession {
    private let defaults = SharedDefaults.store
    private let keys = [
        WindowZoom.defaultsKey, AppStorageKeys.General.appearance,
        AppStorageKeys.Music.barCollapsed,
        AppStorageKeys.Music.barAutoHide, AppStorageKeys.Music.gridView,
    ]
    private let priorDefaults: [Any?]
    private let priorZoom = UIScale.current
    private let priorAppearance = NSApplication.shared.appearance
    private let priorPolicy = NSApplication.shared.activationPolicy()
    private let directory: URL? = ProcessInfo.processInfo.environment[
        "EDITH_TEST_CAPTURE_SURFACES"
    ].map { URL(fileURLWithPath: $0, isDirectory: true) }

    init() {
        priorDefaults = keys.map { SharedDefaults.store.object(forKey: $0) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        for key in keys.dropFirst(2) { defaults.removeObject(forKey: key) }
        zoom(1)
    }

    func zoom(_ value: Double) {
        defaults.set(value, forKey: WindowZoom.defaultsKey)
        UIScale.apply(value)
    }

    func restore() {
        EmbeddedMusicRemote.shared.stop()
        for (key, value) in zip(keys, priorDefaults) {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        UIScale.apply(priorZoom)
        NSApplication.shared.appearance = priorAppearance
        NSApplication.shared.setActivationPolicy(priorPolicy)
    }

    func render(
        route: EmbeddedMusicSceneRoute, width: Double, height: Double?, scheme: ColorScheme,
        name: String
    ) async throws -> NSView {
        defaults.set(scheme == .dark ? "dark" : "light", forKey: AppStorageKeys.General.appearance)
        let intrinsic = height == nil
        let presentation = ExtensionPresentationState(
            compact: route == .sidebar || width < UIScale.pt(720), visible: false,
            availableWidth: width, intrinsic: intrinsic)
        let controller = presentation.withContext { Self.controller(route) }
        var measured = height ?? 0
        if intrinsic {
            for _ in 0..<20 {
                await Task.yield()
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
                controller.view.layoutSubtreeIfNeeded()
                measured = controller.view.fittingSize.height
            }
        }
        let margin = intrinsic ? UIScale.pt(24) : 0
        let canvas = CGRect(x: 0, y: 0, width: width, height: measured + margin)
        let window = NSWindow(
            contentRect: canvas, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(
            NSPoint(x: minX - canvas.width - 1000, y: minY - canvas.height - 1000))
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let backdrop = scheme == .dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor.white
        let container = MusicCaptureBackdrop(frame: canvas)
        container.color = backdrop
        window.contentView = container
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: measured)
        container.addSubview(controller.view)
        window.orderBack(nil)
        defer {
            controller.view.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        for _ in 0..<20 {
            await Task.yield()
            container.layoutSubtreeIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(150))
        container.layoutSubtreeIfNeeded()
        #expect(
            !(window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) }),
            Comment(rawValue: name))
        let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: bitmap)
        if margin > 0 {
            let marginRows = Int(Double(bitmap.pixelsHigh) * margin / canvas.height) - 1
            let overdraw = Self.paintedRows(bitmap, above: marginRows, backdrop: backdrop)
            #expect(
                overdraw == 0, Comment(rawValue: "\(name) draws \(overdraw) rows above its frame"))
        }
        if let directory, measured > 0 {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("music-" + name + ".png"))
        }
        return controller.view
    }

    private static func controller(_ route: EmbeddedMusicSceneRoute) -> NSViewController {
        func host(_ content: some View) -> NSViewController {
            NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicSceneLoad {
                        content.environment(\.musicLiquidGlass, false).environment(
                            \.controlActiveState, .key)
                    }
                })
        }
        switch route {
        case .footer: return host(EmbeddedMusicFooterScene().musicWindowDetail())
        case .sidebar: return host(EmbeddedMusicSidebarScene().musicWindowDetail())
        default:
            return NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicEmbeddedPage().environment(\.musicLiquidGlass, false)
                        .environment(\.controlActiveState, .key)
                })
        }
    }

    private static func paintedRows(_ bitmap: NSBitmapImageRep, above rows: Int, backdrop: NSColor)
        -> Int
    {
        guard let expected = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB),
            let wanted = backdrop.usingColorSpace(.sRGB),
            abs(expected.brightnessComponent - wanted.brightnessComponent) < 0.08
        else { return rows }
        var painted = 0
        for y in 0..<min(rows, bitmap.pixelsHigh) {
            let differs = stride(from: 0, to: bitmap.pixelsWide, by: 2).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return false
                }
                return abs(color.redComponent - expected.redComponent) > 0.04
                    || abs(color.greenComponent - expected.greenComponent) > 0.04
                    || abs(color.blueComponent - expected.blueComponent) > 0.04
            }
            if differs { painted += 1 }
        }
        return painted
    }
}

private final class MusicCaptureBackdrop: NSView {
    var color = NSColor.white
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
