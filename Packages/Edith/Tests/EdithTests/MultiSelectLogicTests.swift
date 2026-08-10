import EdithKit
import Testing

@Suite struct MultiSelectLogicTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func toggleAddsAndRemoves() {
        let added = MultiSelectLogic.toggle("b", selection: ["a"])
        #expect(added.selection == ["a", "b"])
        #expect(added.anchor == "b")
        #expect(added.anchorSelected)
        #expect(!added.dismiss)
        let removed = MultiSelectLogic.toggle("b", selection: ["a", "b"])
        #expect(removed.selection == ["a"])
        #expect(!removed.anchorSelected)
    }

    @Test func toggleKeepsAtLeastOneSelected() {
        let outcome = MultiSelectLogic.toggle("a", selection: ["a"])
        #expect(outcome.selection == ["a"])
        #expect(outcome.anchorSelected)
    }

    @Test func plainRowClickSelectsOnlyAndDismisses() {
        let outcome = MultiSelectLogic.rowClick(
            "c", order: order, selection: ["a", "b"], anchor: "a", anchorSelected: true,
            toggleModifier: false, rangeModifier: false)
        #expect(outcome.selection == ["c"])
        #expect(outcome.anchor == "c")
        #expect(outcome.dismiss)
    }

    @Test func modifierRowClickTogglesWithoutDismissing() {
        let outcome = MultiSelectLogic.rowClick(
            "c", order: order, selection: ["a"], anchor: "a", anchorSelected: true,
            toggleModifier: true, rangeModifier: false)
        #expect(outcome.selection == ["a", "c"])
        #expect(!outcome.dismiss)
    }

    @Test func shiftAfterSelectExtendsSelectionAcrossRange() {
        let outcome = MultiSelectLogic.rangeApply(
            "d", order: order, selection: ["b"], anchor: "b", anchorSelected: true)
        #expect(outcome.selection == ["b", "c", "d"])
        #expect(outcome.anchor == "b")
        #expect(!outcome.dismiss)
    }

    @Test func shiftAfterDeselectClearsRange() {
        let start = MultiSelectLogic.toggle("a", selection: Set(order))
        #expect(start.selection == ["b", "c", "d", "e"])
        #expect(!start.anchorSelected)
        let outcome = MultiSelectLogic.rangeApply(
            "d", order: order, selection: start.selection, anchor: start.anchor,
            anchorSelected: start.anchorSelected)
        #expect(outcome.selection == ["e"])
        #expect(outcome.anchor == "a")
        #expect(!outcome.anchorSelected)
    }

    @Test func shiftDeselectExtendsWithoutReselectingGap() {
        let outcome = MultiSelectLogic.rangeApply(
            "e", order: order, selection: ["a", "c", "e"], anchor: "c", anchorSelected: false)
        #expect(outcome.selection == ["a"])
    }

    @Test func rangeKeepsExistingSelectionOutsideSpan() {
        let outcome = MultiSelectLogic.rangeApply(
            "c", order: order, selection: ["a", "e"], anchor: "b", anchorSelected: true)
        #expect(outcome.selection == ["a", "b", "c", "e"])
    }

    @Test func rangeHandlesReversedSpan() {
        let outcome = MultiSelectLogic.rangeApply(
            "a", order: order, selection: ["c"], anchor: "c", anchorSelected: true)
        #expect(outcome.selection == ["a", "b", "c"])
    }

    @Test func rangeDeselectNeverEmptiesSelection() {
        let outcome = MultiSelectLogic.rangeApply(
            "e", order: order, selection: Set(order), anchor: "a", anchorSelected: false)
        #expect(outcome.selection == ["e"])
    }

    @Test func rangeWithoutAnchorFallsBackToToggle() {
        let anchorless = MultiSelectLogic.rangeApply(
            "d", order: order, selection: ["a"], anchor: nil, anchorSelected: true)
        #expect(anchorless.selection == ["a", "d"])
        let stale = MultiSelectLogic.rangeApply(
            "d", order: order, selection: ["a"], anchor: "gone", anchorSelected: true)
        #expect(stale.selection == ["a", "d"])
        #expect(!stale.dismiss)
    }

    @Test func shiftRowClickRoutesToRangeApply() {
        let outcome = MultiSelectLogic.rowClick(
            "d", order: order, selection: ["b"], anchor: "b", anchorSelected: true,
            toggleModifier: false, rangeModifier: true)
        #expect(outcome.selection == ["b", "c", "d"])
        #expect(!outcome.dismiss)
    }

    @Test func actionClickSelectsOnlyThenAll() {
        let only = MultiSelectLogic.actionClick("b", order: order, selection: Set(order))
        #expect(only.selection == ["b"])
        #expect(!only.dismiss)
        let all = MultiSelectLogic.actionClick("b", order: order, selection: ["b"])
        #expect(all.selection == Set(order))
    }

    @Test func actionLabelFlipsForSoleSelection() {
        #expect(MultiSelectLogic.actionLabel("b", selection: ["a", "b"]) == "Only")
        #expect(MultiSelectLogic.actionLabel("b", selection: ["b"]) == "All")
    }

    @Test func selectAllCoversEveryOption() {
        let outcome = MultiSelectLogic.selectAll(order: order)
        #expect(outcome.selection == Set(order))
        #expect(outcome.anchorSelected)
        #expect(!outcome.dismiss)
    }
}
