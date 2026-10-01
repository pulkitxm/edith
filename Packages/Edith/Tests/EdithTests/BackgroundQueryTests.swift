import Foundation
import Testing

@testable import EdithKit

@Suite struct BackgroundQueryTests {
    @MainActor
    @Test func latestGenerationWinsAndWorkLeavesTheMainActor() async {
        let thread = BackgroundQueryThreadFlag()
        BackgroundQuery.recordThread = { thread.main = Thread.isMainThread }
        defer { BackgroundQuery.recordThread = nil }
        let entries = (0..<20).map { index in
            ClipboardEntry(
                sha256: "sha-\(index)", types: ["public.utf8-plain-text"], ext: "txt",
                sourceApp: "Notes", sourceBundleID: nil, size: 1, preview: "item \(index)")
        }
        async let older = BackgroundQuery.shared.clipboardRows(
            entries: entries, query: "item 1", category: nil, pinToTop: true, generation: 1)
        async let newer = BackgroundQuery.shared.clipboardRows(
            entries: entries, query: "item 12", category: nil, pinToTop: true, generation: 2)
        let first = await older
        let second = await newer
        #expect(thread.main == false)
        #expect(
            !BackgroundQuery.shouldApply(generation: first.generation, current: second.generation))
        #expect(BackgroundQuery.shouldApply(generation: second.generation, current: 2))
        #expect(second.rows.map(\.preview) == ["item 12"])
    }

    @Test func clipboardSearchDoesNotArrangeSynchronously() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/EdithHelper/Features/Clipboard/Views/ClipboardPanelView.swift"),
            encoding: .utf8)
        let change = try #require(source.range(of: ".onChange(of: filterText)"))
        let next = try #require(
            source.range(
                of: ".onChange(of: store.revision)", range: change.upperBound..<source.endIndex)
        )
        let body = source[change.lowerBound..<next.lowerBound]
        #expect(body.contains("scheduleClipboardQuery"))
        #expect(!body.contains("palette.search"))
        #expect(!body.contains("ClipboardActions.arrange"))
        #expect(source.contains("static let pageSize = 80"))
    }

    @Test func objectListPagesAndClipRailStayBounded() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith")
        let explorer = try String(
            contentsOf: root.appendingPathComponent(
                "Features/Database/Models/DatabaseObjectExplorerModel.swift"),
            encoding: .utf8)
        let workbench = try String(
            contentsOf: root.appendingPathComponent(
                "Features/Database/Views/DatabaseWorkbenchView.swift"),
            encoding: .utf8)
        let video = try String(
            contentsOf: root.appendingPathComponent("Features/VideoEditor/VideoEditorPage.swift"),
            encoding: .utf8)
        #expect(explorer.contains("try DatabasePageSize(100)"))
        #expect(workbench.contains("List {"))
        #expect(workbench.contains("appending: true"))
        #expect(!workbench.contains("Menu {"))
        #expect(video.contains("LazyVStack(alignment: .leading, spacing: UIScale.pt(6))"))
    }
}

private final class BackgroundQueryThreadFlag: @unchecked Sendable {
    var main = true
}
