import Foundation
import Testing

@testable import Edith

@Suite @MainActor struct AttentionMockStoreTests {
    @Test func mockCoversThirtyOneCompleteDates() {
        let store = AttentionMockStore()

        #expect(store.allDates.count == 31)
        #expect(store.segments.count >= 400)
        #expect(store.mediaSessions.count == 93)
        #expect(store.focusSessions.count >= 40)
        #expect(store.allDates.first == store.firstDate)
        #expect(store.allDates.last == store.lastDate)
    }

    @Test func rangesSelectExpectedNumberOfDays() {
        let store = AttentionMockStore()

        store.selectedRange = .day
        #expect(store.visibleDates.count == 1)
        store.selectedRange = .week
        #expect(store.visibleDates.count == 7)
        store.selectedRange = .month
        #expect(store.visibleDates.count == 31)
    }

    @Test func listeningRemainsSeparateFromElapsedContext() {
        let store = AttentionMockStore()
        let summary = store.summary(for: store.lastDate)

        #expect(summary.musicSeconds > 0)
        #expect(summary.activeSeconds > 0)
        #expect(summary.musicSeconds != summary.activeSeconds)
    }

    @Test func correctionUpdatesPresenceAndCategory() {
        let store = AttentionMockStore()
        let segment = store.daySegments[0]
        store.selectedSegmentID = segment.id

        store.correctSelectedSegment(
            presence: .uncertain, categoryID: "communication-personal")

        #expect(store.selectedSegment?.presence == .uncertain)
        #expect(store.selectedSegment?.categoryID == "communication-personal")
        #expect(store.selectedSegment?.confidence == 1)
    }

    @Test func categoryRuleReclassifiesMatchingHistory() {
        let store = AttentionMockStore()
        let identity = store.identities.first { $0.name == "WhatsApp" }!

        store.assignCategory("communication-personal", to: identity.id)

        #expect(
            store.identities.first { $0.id == identity.id }?.categoryID == "communication-personal")
        #expect(
            store.segments.filter { $0.service == identity.name }.allSatisfy {
                $0.categoryID == "communication-personal"
            })
    }

    @Test func focusAndBrowserInteractionsAreMutable() {
        let store = AttentionMockStore()
        let profile = store.browserProfiles.first!

        store.beginFocus("flow")
        #expect(store.activeFocusTemplateID == "flow")
        store.endFocus()
        #expect(store.activeFocusTemplateID == nil)

        let initialConnection = profile.connected
        store.toggleBrowser(profile.id)
        #expect(
            store.browserProfiles.first { $0.id == profile.id }?.connected == !initialConnection)
    }

    @Test func setupCompletesEveryGuidedStage() {
        let store = AttentionMockStore()
        store.resetSetup()

        for _ in store.setupSteps.indices { store.advanceSetup() }

        let setupComplete = store.setupSteps.allSatisfy { $0.completed }
        #expect(setupComplete)
        #expect(!store.showSetup)
    }
}
