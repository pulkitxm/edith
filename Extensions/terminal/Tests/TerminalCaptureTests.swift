import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalCaptureTests {
    enum Fixture: String, CaseIterable {
        case empty
        case running
        case broadcast
        case ended
        case loading
    }

    static let variants: [(name: String, size: NSSize, dark: Bool, scale: Double)] = [
        ("regular-light", NSSize(width: 1100, height: 760), false, 1),
        ("regular-dark", NSSize(width: 1100, height: 760), true, 1),
        ("wide-light", NSSize(width: 1600, height: 900), false, 1),
        ("compact-light", NSSize(width: 640, height: 700), false, 1),
        ("compact-dark", NSSize(width: 640, height: 700), true, 1),
        ("zoom-dark", NSSize(width: 1100, height: 760), true, 1.6),
    ]

    @Test(arguments: Fixture.allCases)
    func everyTerminalStateFitsRegularCompactAndZoomedWindows(_ fixture: Fixture) async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for variant in Self.variants {
            UIScale.apply(variant.scale)
            let engine = TerminalTestFixture.engine()
            let remote = try TerminalTestFixture.remote(engine)
            let opened = fixture == .running || fixture == .broadcast ? 3 : 0
            for _ in 0..<opened { await remote.open() }
            let model = TerminalTabsModel(client: remote)
            model.synchronize()
            model.broadcast = fixture == .broadcast
            let presentation = TerminalSessionPresentation.make(
                started: false, exitMessage: "Session ended with status 1.")
            let content: AnyView =
                fixture == .ended
                ? AnyView(
                    TerminalSessionUnavailableView(presentation: presentation) { _ in }
                        .background(
                            Color(nsColor: TerminalPalette.edith(dark: variant.dark).background)))
                : fixture == .loading
                    ? AnyView(
                        TerminalLoadingSkeleton(palette: .edith(dark: variant.dark)))
                    : AnyView(TerminalTabsView(model: model, presented: false))
            let host = NSHostingView(
                rootView:
                    content
                    .environment(\.colorScheme, variant.dark ? .dark : .light)
                    .environment(\.controlActiveState, .key))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: variant.size)
            let window = TerminalTestFixture.window(variant.size)
            window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
            window.contentView = host
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= variant.size.width)
            #expect(host.frame.size == variant.size)
            #expect(model.tabs.count == opened)
            #expect(fixture != .ended || presentation.action == .start)
            try Self.capture(host, name: "terminal-\(fixture.rawValue)-\(variant.name)")
            model.stopAll()
            engine.stop()
            window.contentView = nil
        }
    }

    @Test func statusBarsFitActionsAndLongMessagesAtEverySize() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let exit = "Session ended with status 1."
        let failure =
            "Could not paste 3 files into this session because the destination folder no longer exists on disk."
        for variant in Self.variants {
            UIScale.apply(variant.scale)
            let host = NSHostingView(
                rootView:
                    VStack(spacing: 0) {
                        Spacer()
                        TerminalStatusBar(
                            symbolName: "exclamationmark.triangle.fill", message: failure,
                            tint: DashSkin.danger)
                        TerminalStatusBar(
                            symbolName: "stop.circle", message: exit,
                            tint: DashSkin.inkSoft(variant.dark), actionTitle: "Restart")
                    }
                    .background(
                        Color(nsColor: TerminalPalette.edith(dark: variant.dark).background)
                    )
                    .environment(\.colorScheme, variant.dark ? .dark : .light)
                    .environment(\.controlActiveState, .key))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: variant.size)
            let window = TerminalTestFixture.window(variant.size)
            window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
            window.contentView = host
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= variant.size.width)
            try Self.capture(host, name: "terminal-status-bars-\(variant.name)")
            window.contentView = nil
        }
    }

    static func capture(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"]
        else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
