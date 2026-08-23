import AppKit
import EdithCore
import Foundation

public enum ShelfItemOperation: String, CaseIterable, Sendable {
    case open
    case reveal
    case share

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "shelf.item.\(rawValue)"),
            summary: summary, cli: ["shelf", rawValue], effect: .interactive)
    }

    private var summary: String {
        switch self {
        case .open: return "Open a shelf item."
        case .reveal: return "Reveal a shelf item in Finder."
        case .share: return "Share a shelf item."
        }
    }
}

public enum ShelfItemOperationExecution {
    public static func payload(_ operation: ShelfItemOperation, itemIDs: [UUID]) -> [String: Any] {
        ["operation": operation.rawValue, "itemIDs": itemIDs.map(\.uuidString)]
    }

    public static func request(_ payload: [AnyHashable: Any])
        -> (operation: ShelfItemOperation, itemIDs: Set<UUID>)?
    {
        guard let raw = payload["operation"] as? String,
            let operation = ShelfItemOperation(rawValue: raw),
            let values = payload["itemIDs"] as? [String]
        else { return nil }
        return (operation, Set(values.compactMap(UUID.init(uuidString:))))
    }

    @MainActor
    @discardableResult
    public static func perform(
        _ operation: ShelfItemOperation, urls: [URL],
        open: @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        reveal: @MainActor ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        },
        share: (@MainActor ([URL]) -> Void)? = nil
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        switch operation {
        case .open: urls.forEach(open)
        case .reveal: reveal(urls)
        case .share:
            guard let share else { return false }
            share(urls)
        }
        return true
    }
}
