import Foundation

public actor BackgroundQuery {
    public static let shared = BackgroundQuery()
    public static var recordThread: (@Sendable () -> Void)?

    public func clipboardRows(
        entries: [ClipboardEntry], query: String, category: ClipboardCategory?, pinToTop: Bool,
        generation: UInt
    ) -> (generation: UInt, rows: [ClipboardEntry]) {
        Self.recordThread?()
        let arranged = ClipboardActions.arrange(entries, query: query, pinToTop: pinToTop)
        let rows =
            category.map { wanted in
                arranged.filter { ClipboardCategory($0) == wanted }
            } ?? arranged
        return (generation, rows)
    }

    public nonisolated static func shouldApply(generation: UInt, current: UInt) -> Bool {
        generation == current
    }
}
