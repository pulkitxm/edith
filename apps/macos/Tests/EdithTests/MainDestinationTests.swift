import Testing
@testable import Edith

@Suite struct MainDestinationTests {
    @Test func sidebarSectionsPartitionAllDestinations() {
        let listed = MainDestination.homeItems + MainDestination.appItems
        #expect(Set(listed) == Set(MainDestination.allCases))
        #expect(listed.count == MainDestination.allCases.count)
    }

    @Test func rawValuesRoundTrip() {
        for destination in MainDestination.allCases {
            #expect(MainDestination(rawValue: destination.rawValue) == destination)
        }
    }

    @Test func titlesAreUniqueAndNonEmpty() {
        let titles = MainDestination.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test func iconsAreUniqueAndNonEmpty() {
        let icons = MainDestination.allCases.map(\.icon)
        #expect(Set(icons).count == icons.count)
        #expect(icons.allSatisfy { !$0.isEmpty })
    }

    @Test func paperBackgroundOnlyForHomeItems() {
        for destination in MainDestination.homeItems {
            #expect(destination.usesPaperBackground)
        }
        for destination in MainDestination.appItems {
            #expect(!destination.usesPaperBackground)
        }
    }
}
