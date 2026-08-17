import Testing
@testable import EdithHelper

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
}
