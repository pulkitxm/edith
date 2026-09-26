import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

private struct ClipboardMutationFailure: LocalizedError {
    var errorDescription: String? { "The clipboard index is read-only." }
}

@MainActor
@Suite(.serialized) struct ClipboardPanelNavigationTests {
    private func entry(_ id: String, _ preview: String, age: Double) -> ClipboardEntry {
        ClipboardEntry(
            id: id, sha256: id, types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: "Notes", sourceBundleID: nil,
            createdAt: Date().addingTimeInterval(-age), size: 1, preview: preview)
    }

    private func store(
        _ entries: [ClipboardEntry], mutationsFail: Bool = false
    ) async throws -> ClipboardStore {
        let client = AgentClipboardClient { operation, _ in
            if operation == AgentClipboardOperation.snapshot {
                return try AgentPayload.encode(
                    ClipboardSnapshot(entries: entries, revision: "fixture", total: entries.count))
            }
            if mutationsFail { throw ClipboardMutationFailure() }
            return try AgentPayload.encode(
                ClipboardMutationResult(changed: 1, total: entries.count))
        }
        let store = ClipboardStore(client: client, capturesPasteboard: false)
        for _ in 0..<200 where store.entries.count != entries.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(store.entries.count == entries.count)
        return store
    }

    private var history: [ClipboardEntry] {
        [
            entry("a", "first", age: 1), entry("b", "https://example.com", age: 2),
            entry("c", "#ff26a1", age: 3), entry("d", "last", age: 4),
        ]
    }

    @Test func largeHistoriesRenderOnlyTheFirstPage() {
        let many = (0..<5_000).map { entry("e\($0)", "clip \($0)", age: Double($0)) }
        var palette = ClipboardPalette(entries: many)

        let page = palette.sections(limit: ClipboardPanelView.pageSize)
        #expect(ClipboardPanelView.pageSize == 80)
        #expect(page.flatMap(\.entries).count == ClipboardPanelView.pageSize)
        #expect(palette.rows.count == 5_000)

        palette.jump(toTop: false)
        #expect(palette.selectedIndex == 4_999)
    }

    @Test func clearSurfacesPersistenceFailure() async throws {
        let target = entry("target", "target", age: 0)
        let store = try await store([target], mutationsFail: true)
        defer { store.shutdown() }
        let plan = ClipboardOperationExecution.clearPlan(entries: [target], keepPinned: true)

        store.clear(plan)
        for _ in 0..<100 where store.mutationError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.mutationError == "The clipboard index is read-only.")
    }

    @Test func deletingFromThePaletteMovesSelectionToTheNextClip() async throws {
        let store = try await store(history)
        defer { store.shutdown() }
        var palette = ClipboardPalette(entries: store.entries)
        palette.select("b")

        store.delete("b")
        palette.replace(store.entries)

        #expect(palette.rows.map(\.id) == ["a", "c", "d"])
        #expect(palette.selectedID == "c")
    }

    @Test func pinningKeepsTheSelectionOnThePinnedClip() async throws {
        let store = try await store(history)
        defer { store.shutdown() }
        var palette = ClipboardPalette(entries: store.entries)
        palette.select("d")

        store.togglePin("d")
        palette.replace(store.entries)

        #expect(palette.rows.first?.id == "d")
        #expect(palette.rows.first?.pinned == true)
        #expect(palette.selectedID == "d")
        #expect(palette.sections().first?.title == ClipboardTimeline.pinnedTitle)
    }

    @Test func failedDeleteRestoresTheClip() async throws {
        let store = try await store(history, mutationsFail: true)
        defer { store.shutdown() }

        store.delete("a")
        #expect(!store.entries.contains { $0.id == "a" })
        for _ in 0..<200 where !store.entries.contains(where: { $0.id == "a" }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.entries.contains { $0.id == "a" })
        #expect(store.mutationError != nil)
    }

    @Test func pauseToggleIsStoredWhereCaptureReadsIt() async throws {
        let store = try await store(history)
        defer {
            store.shutdown()
            SharedDefaults.store.removeObject(forKey: AppStorageKeys.Clipboard.capturePaused)
        }

        store.setCapturePaused(true)
        #expect(ClipboardCapturePolicy.isPaused())
        #expect(
            ClipboardCapturePolicy.decide(types: ["public.utf8-plain-text"], sourceBundleID: nil)
                == .skip(.paused))

        store.setCapturePaused(false)
        #expect(!ClipboardCapturePolicy.isPaused())
        #expect(store.mutationError == nil)
    }
}
