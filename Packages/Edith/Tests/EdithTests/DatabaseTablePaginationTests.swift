import EdithDatabase
import Testing

@testable import Edith

@Suite("Database table pagination")
struct DatabaseTablePaginationTests {
    @Test("A continuation loads when the viewport approaches the end")
    func nearEndLoads() {
        var gate = DatabaseTablePaginationGate()
        let continuation = DatabaseContinuationToken(rawValue: "page-2")

        let shouldLoad = gate.shouldLoadMore(
            continuation: continuation,
            isLoading: false,
            visibleMaxY: 710,
            contentMaxY: 1_000,
            rowHeight: 30)

        #expect(shouldLoad)
    }

    @Test("The same continuation only loads once automatically")
    func continuationLoadsOnce() {
        var gate = DatabaseTablePaginationGate()
        let continuation = DatabaseContinuationToken(rawValue: "page-2")

        let firstAttempt = gate.shouldLoadMore(
            continuation: continuation,
            isLoading: false,
            visibleMaxY: 1_000,
            contentMaxY: 1_000,
            rowHeight: 30)
        let secondAttempt = gate.shouldLoadMore(
            continuation: continuation,
            isLoading: false,
            visibleMaxY: 1_000,
            contentMaxY: 1_000,
            rowHeight: 30)

        #expect(firstAttempt)
        #expect(!secondAttempt)
    }

    @Test("A new continuation chains while an underfilled table remains at the end")
    func newContinuationChains() {
        var gate = DatabaseTablePaginationGate()

        let firstPage = gate.shouldLoadMore(
            continuation: DatabaseContinuationToken(rawValue: "page-2"),
            isLoading: false,
            visibleMaxY: 200,
            contentMaxY: 200,
            rowHeight: 30)
        let secondPage = gate.shouldLoadMore(
            continuation: DatabaseContinuationToken(rawValue: "page-3"),
            isLoading: false,
            visibleMaxY: 200,
            contentMaxY: 200,
            rowHeight: 30)

        #expect(firstPage)
        #expect(secondPage)
    }

    @Test("Loading, missing continuations, and distant viewports do not paginate")
    func inactiveStatesDoNotLoad() {
        var gate = DatabaseTablePaginationGate()
        let continuation = DatabaseContinuationToken(rawValue: "page-2")

        let missingContinuation = gate.shouldLoadMore(
            continuation: nil,
            isLoading: false,
            visibleMaxY: 1_000,
            contentMaxY: 1_000,
            rowHeight: 30)
        let loading = gate.shouldLoadMore(
            continuation: continuation,
            isLoading: true,
            visibleMaxY: 1_000,
            contentMaxY: 1_000,
            rowHeight: 30)
        let distantViewport = gate.shouldLoadMore(
            continuation: continuation,
            isLoading: false,
            visibleMaxY: 500,
            contentMaxY: 1_000,
            rowHeight: 30)

        #expect(!missingContinuation)
        #expect(!loading)
        #expect(!distantViewport)
    }

    @Test("A fresh scroll gesture can retry the same continuation")
    func rearmRetries() {
        var gate = DatabaseTablePaginationGate()
        let continuation = DatabaseContinuationToken(rawValue: "page-2")

        let firstAttempt = gate.shouldLoadMore(
            continuation: continuation,
            isLoading: false,
            visibleMaxY: 1_000,
            contentMaxY: 1_000,
            rowHeight: 30)
        gate.rearm()
        let retry = gate.shouldLoadMore(
            continuation: continuation,
            isLoading: false,
            visibleMaxY: 1_000,
            contentMaxY: 1_000,
            rowHeight: 30)

        #expect(firstAttempt)
        #expect(retry)
    }
}
