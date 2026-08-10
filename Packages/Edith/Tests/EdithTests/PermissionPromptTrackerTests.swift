import Testing

@testable import EdithKit

@Suite struct PermissionPromptTrackerTests {
    @Test func hintWaitsForTheSecondPrompt() {
        #expect(!PermissionPromptTracker.shouldHint(count: 1, alreadyShown: false))
        #expect(PermissionPromptTracker.shouldHint(count: 2, alreadyShown: false))
        #expect(PermissionPromptTracker.shouldHint(count: 7, alreadyShown: false))
    }

    @Test func hintShowsOnlyOnce() {
        #expect(!PermissionPromptTracker.shouldHint(count: 2, alreadyShown: true))
        #expect(!PermissionPromptTracker.shouldHint(count: 9, alreadyShown: true))
    }
}
