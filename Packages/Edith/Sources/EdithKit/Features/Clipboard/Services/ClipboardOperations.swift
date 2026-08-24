import AppKit
import EdithCore
import Foundation

public enum ClipboardOperation: String, CaseIterable, Sendable {
    case stats
    case copy
    case pin
    case unpin
    case remove

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "clipboard.\(rawValue)"), summary: summary,
            cli: ["clipboard", command], effect: effect, requiresPreview: self == .remove)
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
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .stats: .read
        case .copy, .pin, .unpin: .write
        case .remove: .destructive
        }
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

    @discardableResult
    public static func perform(
        _ operation: ClipboardOperation, entry: ClipboardEntry? = nil,
        asPlainText: Bool = false, pasteboard: NSPasteboard = .general
    ) throws -> ClipboardActions.Outcome {
        guard let entry else { throw ClipboardOperationError.entryRequired }
        switch operation {
        case .stats: throw ClipboardOperationError.entryRequired
        case .copy:
            do {
                return try ClipboardActions.copy(
                    entry, asPlainText: asPlainText, pasteboard: pasteboard)
            } catch ClipboardActionError.blobMissing {
                throw ClipboardOperationError.blobMissing
            }
        case .pin: return try ClipboardActions.setPinned(true, ids: [entry.id])
        case .unpin: return try ClipboardActions.setPinned(false, ids: [entry.id])
        case .remove: return try ClipboardActions.delete(ids: [entry.id])
        }
    }
}
