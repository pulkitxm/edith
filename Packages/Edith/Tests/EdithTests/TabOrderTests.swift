import Testing
@testable import EdithHelper

@Suite struct TabOrderTests {
    @Test func appendsTabsMissingFromSavedOrder() {
        #expect(
            orderedTabIDs("usage,music,system")
                == ["usage", "music", "system", "network", "calendar"])
    }

    @Test func preservesACustomOrder() {
        let order = "calendar,system,music,usage"
        #expect(orderedTabIDs(order) == ["calendar", "system", "music", "usage", "network"])
    }

    @Test func dropsUnknownIDs() {
        #expect(
            orderedTabIDs("usage,bogus,music")
                == ["usage", "music", "system", "network", "calendar"])
    }

    @Test func emptyStringYieldsAllTabsInDefaultOrder() {
        #expect(orderedTabIDs("") == allTabs.map(\.id))
    }

    @Test func alwaysReturnsEveryTabExactlyOnce() {
        #expect(Set(orderedTabIDs("system")) == Set(allTabs.map(\.id)))
        #expect(orderedTabIDs("system").count == allTabs.count)
    }
}
