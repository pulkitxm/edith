import Testing
import Foundation

@testable import EdithHelper
@testable import EdithKit

private struct ClipboardMutationFailure: LocalizedError {
    var errorDescription: String? { "The clipboard index is read-only." }
}

@Suite struct ClipboardPanelNavigationTests {
    @Test func commandDownTargetsTheBottomShownRow() {
        let target = ClipboardPanelView.jumpTargetIndex(
            itemCount: 500, top: false, shownEdgeIndex: 23, renderedCount: 80)

        #expect(target == 23)
    }

    @Test func commandDownFallsBackToTheRenderedPage() {
        let target = ClipboardPanelView.jumpTargetIndex(
            itemCount: 500, top: false, shownEdgeIndex: nil, renderedCount: 80)

        #expect(target == 79)
    }

    @Test func commandDownIgnoresAStaleUnrenderedFrame() {
        let target = ClipboardPanelView.jumpTargetIndex(
            itemCount: 500, top: false, shownEdgeIndex: 480, renderedCount: 80)

        #expect(target == 79)
    }

    @Test func commandUpTargetsTheFirstRow() {
        let target = ClipboardPanelView.jumpTargetIndex(
            itemCount: 500, top: true, shownEdgeIndex: nil, renderedCount: 80)

        #expect(target == 0)
    }

    @Test @MainActor func clearSurfacesPersistenceFailure() async throws {
        let client = AgentClipboardClient { operation, _ in
            if operation == AgentClipboardOperation.snapshot {
                return try AgentPayload.encode(
                    ClipboardSnapshot(entries: [], revision: "fixture", total: 0))
            }
            throw ClipboardMutationFailure()
        }
        let store = ClipboardStore(client: client, capturesPasteboard: false)
        defer { store.shutdown() }
        let entry = ClipboardEntry(
            id: "target", sha256: "target", types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: nil, sourceBundleID: nil, size: 1, preview: "target")
        let plan = ClipboardOperationExecution.clearPlan(
            entries: [entry], keepPinned: true)

        store.clear(plan)
        for _ in 0..<100 where store.mutationError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.mutationError == "The clipboard index is read-only.")
    }
}
