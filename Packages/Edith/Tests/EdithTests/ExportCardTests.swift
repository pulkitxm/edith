import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct ExportCardTests {
    private let usage = UsageShareSnapshot(
        days: [UsageShareDay(period: "2026-08-29", tokens: 12_345, cost: 1)],
        agentCount: 1, repositoryCount: 1)

    @Test func deliveryCopiesPNGDataAndWritesItAtomically() throws {
        let data = try UsageShareRenderer.pngData(snapshot: usage, card: .highlights, scale: 1)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 1_200)
        #expect(bitmap.pixelsHigh == 800)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        try ExportDelivery.copyPNG(data, to: pasteboard)
        #expect(pasteboard.data(forType: .png) == data)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.png")
        try ExportDelivery.write(data, to: file)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func bothFeaturesRenderTheSharedExportSheet() async throws {
        try await render(UsageExportDeck(snapshot: usage), name: "usage")
        try await render(
            CodeStatsExportDeck(
                snapshot: CodeStatsExportSnapshot(report: CodeStatsPageFixture.report(.all))),
            name: "code-stats")
    }

    @Test func exportShortcutRunsOnlyWhenTheSharedButtonIsEnabled() async throws {
        var exports = 0
        let host = try auditHost(
            ExportCardButton(isEnabled: true, help: "Export synthetic cards") { exports += 1 },
            size: CGSize(width: 320, height: 100))
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        window.makeKey()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        let event = try key("e", code: 14, in: window)
        #expect(window.performKeyEquivalent(with: event))
        #expect(exports == 1)
        host.rootView = AnyView(
            ExportCardButton(isEnabled: false, help: "Export synthetic cards") { exports += 1 })
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        _ = window.performKeyEquivalent(with: event)
        #expect(exports == 1)
    }

    @Test func copyShortcutDeliversTheSelectedCardAndShowsFeedback() async throws {
        try await copyShortcut(UsageExportDeck(snapshot: usage), name: "usage")
        try await copyShortcut(
            CodeStatsExportDeck(
                snapshot: CodeStatsExportSnapshot(report: CodeStatsPageFixture.report(.all))),
            name: "code-stats")
    }

    private func copyShortcut<Deck: ExportCardDeck>(_ deck: Deck, name: String) async throws {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let host = NSHostingView(
            rootView: AnyView(
                ExportCardInteractionHost(
                    deck: deck, title: "Share \(name)", pasteboard: pasteboard
                )
                .environment(\.colorScheme, .dark)
                .environment(\.scenePhase, .active)))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 610)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        window.makeKey()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        let evidence = ProcessInfo.processInfo.environment["EDITH_EXPORT_EVIDENCE_DIR"].map {
            URL(fileURLWithPath: $0)
        }
        if let evidence {
            try FileManager.default.createDirectory(
                at: evidence, withIntermediateDirectories: true)
            try capture(host, to: evidence.appendingPathComponent("copy-\(name)-0.png"))
        }
        #expect(window.performKeyEquivalent(with: try key("c", code: 8, in: window)))
        if let evidence {
            for frame in 1..<13 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                try capture(host, to: evidence.appendingPathComponent("copy-\(name)-\(frame).png"))
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(pasteboard.data(forType: .png) != nil)
        var text = try auditText(host)
        #expect(text.contains("Copied!"))
        #expect(text.contains("Image copied"))
        #expect(
            window.performKeyEquivalent(
                with: try key("\u{F703}", code: 124, modifiers: [], in: window)))
        try await Task.sleep(for: .milliseconds(300))
        text = try auditText(host)
        #expect(text.contains(deck.title(for: deck.cards[1])))
        #expect(!text.contains("Copied!"))
        #expect(window.performKeyEquivalent(with: try key("c", code: 8, in: window)))
        try await Task.sleep(for: .milliseconds(100))
        let expected = try ExportCardRenderer.pngData(deck.content(for: deck.cards[1]))
        #expect(pasteboard.data(forType: .png) == expected)
    }

    private func capture(_ host: NSView, to url: URL) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func key(
        _ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = .command,
        in window: NSWindow
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code))
    }

    private func render<Deck: ExportCardDeck>(_ deck: Deck, name: String) async throws {
        let host = try auditHost(
            ExportCardSheet(deck: deck, title: "Share \(name)", busy: .constant(false)) {},
            size: CGSize(width: 720, height: 610))
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let text = try auditText(host)
        #expect(text.contains("Copy image"))
        #expect(text.contains("Save PNG"))
        #expect(text.contains(deck.title(for: try #require(deck.cards.first))))
        if let path = ProcessInfo.processInfo.environment["EDITH_EXPORT_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("export-\(name).png"))
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }
}

private struct ExportCardInteractionHost<Deck: ExportCardDeck>: View {
    let deck: Deck
    let title: String
    let pasteboard: NSPasteboard
    @State private var busy = false

    var body: some View {
        ExportCardSheet(
            deck: deck, title: title, busy: $busy, onDismiss: {}, pasteboard: pasteboard)
    }
}
