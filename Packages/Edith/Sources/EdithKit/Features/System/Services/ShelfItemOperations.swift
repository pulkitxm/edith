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
        case .open: return "Open shelf items."
        case .reveal: return "Reveal shelf items in Finder."
        case .share: return "Share shelf items."
        }
    }
}

public enum ShelfItemOperationExecution {
    public static let requestIDKey = "requestID"
    public static let okKey = "ok"
    public static let errorKey = "error"

    public static func payload(
        _ operation: ShelfItemOperation, itemIDs: [UUID], requestID: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "operation": operation.rawValue, "itemIDs": itemIDs.map(\.uuidString),
        ]
        if let requestID { payload[requestIDKey] = requestID }
        return payload
    }

    public static func request(_ payload: [AnyHashable: Any])
        -> (operation: ShelfItemOperation, itemIDs: Set<UUID>, requestID: String?)?
    {
        guard let raw = payload["operation"] as? String,
            let operation = ShelfItemOperation(rawValue: raw),
            let values = payload["itemIDs"] as? [String], !values.isEmpty
        else { return nil }
        let itemIDs = values.compactMap(UUID.init(uuidString:))
        guard itemIDs.count == values.count, Set(itemIDs).count == values.count else { return nil }
        let requestID = payload[requestIDKey] as? String
        guard requestID?.isEmpty != true else { return nil }
        return (
            operation, Set(itemIDs), requestID
        )
    }

    public static func resultPayload(
        requestID: String, ok: Bool, error: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [requestIDKey: requestID, okKey: ok]
        if let error { payload[errorKey] = error }
        return payload
    }

    @MainActor
    @discardableResult
    public static func perform(
        _ operation: ShelfItemOperation, urls: [URL],
        open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        reveal: @MainActor ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        },
        share: (@MainActor ([URL]) -> Bool)? = nil
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        switch operation {
        case .open: return urls.map(open).allSatisfy { $0 }
        case .reveal: reveal(urls)
        case .share:
            guard let share else { return false }
            return share(urls)
        }
        return true
    }
}
