import Foundation
import Observation

struct DatabaseQueryHistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let operation: DatabaseSearchQueryOperation
}

@MainActor
@Observable
final class DatabaseQueryHistory {
    static let capacity = 20
    static let maximumQueryBytes = 16_384
    private(set) var entries: [DatabaseQueryHistoryEntry] = []

    func record(_ text: String, operation: DatabaseSearchQueryOperation) {
        guard text.utf8.count <= Self.maximumQueryBytes else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.removeAll { $0.text == text && $0.operation == operation }
        entries.insert(DatabaseQueryHistoryEntry(text: text, operation: operation), at: 0)
        if entries.count > Self.capacity { entries.removeLast() }
    }

    func clear() { entries = [] }
}
