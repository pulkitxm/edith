import Testing
@testable import EdithExtensionUI

struct SurfaceSliderEditingTests {
    @Test func dragUpdatesStayLocalAndCommitExactlyOnceWhenEditingEnds() {
        var draft = SurfaceSliderDraft(value: 0.2)
        #expect(draft.editingChanged(true) == nil)
        for value in [0.3, 0.4, 0.7] {
            draft.set(value)
            draft.synchronize(0.1)
            #expect(draft.isEditing && draft.value == value)
        }
        #expect(draft.editingChanged(false) == 0.7)
        #expect(draft.editingChanged(false) == nil)
        draft.synchronize(0.6)
        #expect(draft.value == 0.6)
        #expect(draft.editingChanged(true) == nil)
        #expect(draft.editingChanged(false) == nil)
    }

    @Test func leavingTheCardCancelsTheDraftAndInvalidValuesNeverLeaveTheControl() {
        var draft = SurfaceSliderDraft(value: 0.2)
        _ = draft.editingChanged(true)
        draft.set(0.9)
        draft.cancel()
        #expect(draft.value == 0.2 && !draft.isEditing)
        #expect(draft.editingChanged(false) == nil)
        draft.set(.nan)
        #expect(draft.value == 0.2)
        draft.set(2)
        #expect(draft.value == 1)
        draft.synchronize(.infinity)
        #expect(draft.value == 1)
    }
}
