import EdithExtensionUI
import Testing

@testable import UsageExtension

@Suite("UsageEmptyStateTests")
struct UsageEmptyStateTests {
    @Test func loadedDataNeverShowsAnEmptyState() {
        #expect(
            UsageEmptyState.resolve(state: .error, loaded: true, updating: false, errorMessage: "x")
                == .none)
        #expect(
            UsageEmptyState.resolve(state: .empty, loaded: true, updating: false, errorMessage: nil)
                == .none)
    }

    @Test func loadingKeepsTheSkeleton() {
        #expect(
            UsageEmptyState.resolve(
                state: .loading, loaded: false, updating: false, errorMessage: nil) == .none)
    }

    @Test func missingDataIsFirstRunUntilACollectionStarts() {
        #expect(
            UsageEmptyState.resolve(
                state: .empty, loaded: false, updating: false, errorMessage: nil)
                == .firstRun)
        #expect(
            UsageEmptyState.resolve(state: .empty, loaded: false, updating: true, errorMessage: nil)
                == .collecting)
    }

    @Test func failuresCarryTheirMessage() {
        #expect(
            UsageEmptyState.resolve(
                state: .error, loaded: false, updating: false, errorMessage: "disk full")
                == .failed("disk full"))
        #expect(
            UsageEmptyState.resolve(
                state: .offline, loaded: false, updating: false, errorMessage: nil)
                == .failed("Usage data could not be read."))
    }
}
