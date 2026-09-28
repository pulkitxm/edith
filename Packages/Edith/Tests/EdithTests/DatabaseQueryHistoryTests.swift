import EdithDatabase
import Foundation
import Testing

@testable import Edith

@MainActor
struct DatabaseQueryHistoryTests {
    @Test func historyDeduplicatesByTextAndOperationAndKeepsMostRecentFirst() {
        let history = DatabaseQueryHistory()
        history.record("  SELECT 1\n", operation: .search)
        history.record("SELECT 2", operation: .search)
        history.record("SELECT 1", operation: .search)
        #expect(history.entries.map(\.text) == ["SELECT 1", "SELECT 2"])
        history.record("SELECT 1", operation: .aggregate)
        #expect(history.entries.count == 3)
        #expect(history.entries.first?.operation == .aggregate)
        history.clear()
        #expect(history.entries.isEmpty)
    }

    @Test func historyBoundsRetainedQueriesAndBytesWithoutTruncatingCommands() {
        let history = DatabaseQueryHistory()
        for index in 0..<100 { history.record("SELECT \(index)", operation: .search) }
        #expect(history.entries.count == DatabaseQueryHistory.capacity)
        #expect(history.entries.first?.text == "SELECT 99")
        #expect(history.entries.last?.text == "SELECT 80")
        let before = history.entries
        history.record(" \n ", operation: .search)
        history.record(
            String(repeating: "é", count: DatabaseQueryHistory.maximumQueryBytes),
            operation: .search)
        #expect(history.entries == before)
        let exact = String(repeating: "x", count: DatabaseQueryHistory.maximumQueryBytes)
        history.record(exact, operation: .search)
        #expect(history.entries.first?.text == exact)
        #expect(
            history.entries.reduce(0) { $0 + $1.text.utf8.count } <= DatabaseQueryHistory.capacity
                * DatabaseQueryHistory.maximumQueryBytes)
    }
}
