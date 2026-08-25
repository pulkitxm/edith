import AppKit
import EdithCore
import Foundation

public enum ClipboardOperation: String, CaseIterable, Sendable {
    case stats
    case copy
    case pin
    case unpin
    case remove
    case clear

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "clipboard.\(rawValue)"), summary: summary,
            cli: ["clipboard", command], effect: effect,
            requiresPreview: self == .remove || self == .clear)
    }

    private var command: String {
        self == .remove ? "rm" : rawValue
    }

    private var summary: String {
        switch self {
        case .stats: "Summarize clipboard history storage."
        case .copy: "Copy a clipboard entry back to the pasteboard."
        case .pin: "Pin a clipboard entry."
        case .unpin: "Unpin a clipboard entry."
        case .remove: "Remove a clipboard entry."
        case .clear: "Clear selected clipboard history entries."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .stats: .read
        case .copy, .pin, .unpin: .write
        case .remove, .clear: .destructive
        }
    }
}

public struct ClipboardClearPlan: Equatable, Sendable {
    public let targetIDs: [String]
    public let keepPinned: Bool
    public let pinnedKept: Int
    public let remaining: Int

    public init(entries: [ClipboardEntry], keepPinned: Bool) {
        targetIDs = entries.filter { !keepPinned || !$0.pinned }.map(\.id)
        self.keepPinned = keepPinned
        pinnedKept = keepPinned ? entries.filter(\.pinned).count : 0
        remaining = entries.count - targetIDs.count
    }

    public var removed: Int { targetIDs.count }

    public var confirmationTitle: String {
        "Clear \(removed) clipboard \(removed == 1 ? "entry" : "entries")?"
    }

    public var confirmationMessage: String {
        if keepPinned {
            let noun = pinnedKept == 1 ? "entry" : "entries"
            return "\(pinnedKept) pinned \(noun) will be kept. This cannot be undone."
        }
        return "Pinned entries will also be removed. This cannot be undone."
    }
}

public enum ClipboardOperationError: LocalizedError, Equatable {
    case entryRequired
    case blobMissing

    public var errorDescription: String? {
        switch self {
        case .entryRequired: "This clipboard operation requires an entry."
        case .blobMissing: "The stored copy of this clipboard entry is missing."
        }
    }
}

public enum ClipboardOperationExecution {
    public static func stats(_ entries: [ClipboardEntry]? = nil) -> ClipboardActions.Stats {
        ClipboardActions.stats(entries)
    }

    public static func clearPlan(
        entries: [ClipboardEntry]? = nil, keepPinned: Bool
    ) -> ClipboardClearPlan {
        ClipboardClearPlan(
            entries: entries ?? ClipboardRepository.loadEntries(), keepPinned: keepPinned)
    }

    @discardableResult
    public static func clear(_ plan: ClipboardClearPlan) throws -> ClipboardActions.Outcome {
        try ClipboardActions.delete(ids: Set(plan.targetIDs))
    }

    @discardableResult
    public static func perform(
        _ operation: ClipboardOperation, entry: ClipboardEntry? = nil,
        asPlainText: Bool = false, pasteboard: NSPasteboard = .general,
        recordCopy: (String) throws -> ClipboardActions.Outcome = {
            try ClipboardActions.markCopied(id: $0)
        }
    ) throws -> ClipboardActions.Outcome {
        guard let entry else { throw ClipboardOperationError.entryRequired }
        switch operation {
        case .stats, .clear: throw ClipboardOperationError.entryRequired
        case .copy:
            guard
                ClipboardRepository.copyToPasteboard(
                    entry, asPlainText: asPlainText, pasteboard: pasteboard)
            else { throw ClipboardOperationError.blobMissing }
            return try recordCopy(entry.id)
        case .pin: return try ClipboardActions.setPinned(true, ids: [entry.id])
        case .unpin: return try ClipboardActions.setPinned(false, ids: [entry.id])
        case .remove: return try ClipboardActions.delete(ids: [entry.id])
        }
    }
}
