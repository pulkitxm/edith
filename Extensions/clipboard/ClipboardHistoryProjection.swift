import Foundation

public struct ClipboardHistoryProjection {
    private var confirmed: [ClipboardEntry] = []
    private var pending: [(UUID, ClipboardMutation)] = []

    public init() {}

    public var entries: [ClipboardEntry] {
        ClipboardActions.arrange(pending.reduce(confirmed) { Self.apply($1.1, to: $0) })
    }

    public mutating func replace(_ entries: [ClipboardEntry]) { confirmed = entries }

    public mutating func begin(_ id: UUID, mutation: ClipboardMutation) {
        pending.append((id, mutation))
    }

    public mutating func finish(_ id: UUID, succeeded: Bool) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        let mutation = pending.remove(at: index).1
        if succeeded { confirmed = Self.apply(mutation, to: confirmed) }
    }

    private static func apply(_ mutation: ClipboardMutation, to entries: [ClipboardEntry])
        -> [ClipboardEntry]
    {
        let ids = Set(mutation.ids)
        return entries.compactMap { entry in
            guard ids.contains(entry.id) else { return entry }
            var updated = entry
            switch mutation.kind {
            case .delete: return nil
            case .pin: updated.pinned = true
            case .unpin: updated.pinned = false
            case .copied: updated.lastCopiedAt = max(entry.lastCopiedAt, mutation.copiedAt)
            }
            return updated
        }
    }
}
