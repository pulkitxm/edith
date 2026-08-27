import Testing
@testable import EdithHelper

@Suite struct TabOrderTests {
    @Test func appendsTabsMissingFromSavedOrder() {
        #expect(
            orderedTabIDs("usage,music,system")
                == ["usage", "music", "system", "quickActions", "calendar"])
    }

    @Test func preservesACustomOrder() {
        let order = "calendar,system,music,usage"
        #expect(
            orderedTabIDs(order) == ["calendar", "system", "music", "usage", "quickActions"])
    }

    @Test func dropsUnknownIDs() {
        #expect(
            orderedTabIDs("usage,bogus,music")
                == ["usage", "music", "system", "quickActions", "calendar"])
    }

    @Test func emptyStringYieldsAllTabsInDefaultOrder() {
        #expect(orderedTabIDs("") == allTabs.map(\.id))
    }

    @Test func alwaysReturnsEveryTabExactlyOnce() {
        #expect(Set(orderedTabIDs("system")) == Set(allTabs.map(\.id)))
        #expect(orderedTabIDs("system").count == allTabs.count)
    }
}
