import AppKit
import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct UsageShareSheetTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func dashboardExposesTheShareSheet() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent(
                "Sources/Edith/Features/Dashboard/Views/DashboardView.swift"),
            encoding: .utf8)
        #expect(source.contains("Image(systemName: \"square.and.arrow.up\")"))
        #expect(source.contains("OrbitingShareButton"))
        #expect(source.contains("CircularShareText"))
        #expect(source.contains(".linear(duration: 14).repeatForever(autoreverses: false)"))
        #expect(source.contains(".scaleEffect(hovering ? 1.07 : 1)"))
        #expect(source.contains("shareOverlay"))
        #expect(source.contains(".onTapGesture { closeShare() }"))
        #expect(source.contains(".move(edge: .top).combined(with: .opacity)"))
        #expect(source.contains("UsageShareSheet(snapshot: shareSnapshot, onDismiss: closeShare)"))
        #expect(source.contains("model.heatDetail.sorted"))
    }

    @Test func sheetOffersNativeCopyDownloadAndCarouselControls() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent(
                "Sources/Edith/Features/Dashboard/Views/UsageShareSheet.swift"),
            encoding: .utf8)
        #expect(source.contains("Text(\"Copy image\")"))
        #expect(source.contains(".accessibilityLabel(\"Download PNG\")"))
        #expect(source.contains(".frame(width: 600, height: 400)"))
        #expect(source.contains("ShareCarouselArrow"))
        #expect(source.contains("let onDismiss: () -> Void"))
        #expect(source.contains(".onExitCommand { onDismiss() }"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains("@Environment(\\.colorScheme)"))
        #expect(source.contains("private var modalBackground: Color"))
        let sheetBackground =
            "private var sheetBackground: some View {\n"
            + "        modalBackground\n    }"
        #expect(source.contains(sheetBackground))
        #expect(source.contains("UsageShareDelivery.copy(data)"))
        #expect(source.contains("NSSavePanel()"))
        #expect(source.contains("DragGesture"))
        #expect(source.contains("shortcut: .leftArrow"))
        #expect(source.contains("shortcut: .rightArrow"))
        #expect(source.contains(".keyboardShortcut(shortcut, modifiers: [])"))
        #expect(source.contains(".clipped()"))
        #expect(source.contains(".keyboardShortcut(\"c\", modifiers: .command)"))
        #expect(source.contains(".keyboardShortcut(\"s\", modifiers: .command)"))
        #expect(source.contains("copied ? \"checkmark\" : \"doc.on.doc\""))
        #expect(!source.contains(".scaleEffect(configuration.isPressed"))
        #expect(!source.contains("Twitter"))
        #expect(!source.contains("LinkedIn"))
    }

    @Test @MainActor func deliveryCopiesPNGDataAndWritesItAtomically() throws {
        let snapshot = UsageShareSnapshot(
            days: [UsageShareDay(period: "2026-08-29", tokens: 12_345, cost: 1)],
            agentCount: 1, repositoryCount: 1)
        let data = try UsageShareRenderer.pngData(
            snapshot: snapshot, card: .highlights, scale: 1)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        try UsageShareDelivery.copy(data, to: pasteboard)
        #expect(pasteboard.data(forType: .png) == data)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.png")
        try UsageShareDelivery.write(data, to: file)
        #expect(try Data(contentsOf: file) == data)
    }
}
