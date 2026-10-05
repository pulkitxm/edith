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
