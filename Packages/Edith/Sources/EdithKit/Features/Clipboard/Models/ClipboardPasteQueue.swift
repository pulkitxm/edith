import Foundation

public struct ClipboardQueueItem: Codable, Equatable, Identifiable, Sendable {
    public let entry: ClipboardEntry
    public let queuedAt: Date

    public var id: String { entry.id }

    public init(entry: ClipboardEntry, queuedAt: Date = Date()) {
        self.entry = entry
        self.queuedAt = queuedAt
    }
}

public struct ClipboardPasteQueue: Equatable, Sendable {
    public private(set) var items: [ClipboardQueueItem]

    public init(items: [ClipboardQueueItem] = []) {
        self.items = items
    }

    @discardableResult
    public mutating func add(_ entry: ClipboardEntry, at moment: Date = Date())
        -> ClipboardQueueItem
    {
        items.removeAll { $0.id == entry.id }
        let item = ClipboardQueueItem(entry: entry, queuedAt: moment)
        items.append(item)
        return item
    }

    @discardableResult
    public mutating func remove(id: String) -> ClipboardQueueItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    @discardableResult
    public mutating func removeNext() -> ClipboardQueueItem? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    @discardableResult
    public mutating func clear() -> [ClipboardQueueItem] {
        let removed = items
        items.removeAll()
        return removed
    }

    public mutating func retain(entryIDs: Set<String>) {
        items.removeAll { !entryIDs.contains($0.id) }
    }
}

public enum ClipboardQueueAction: String, Codable, Sendable {
    case list
    case add
    case remove
    case clear
    case next
}

public enum ClipboardQueueStatus: String, Codable, Sendable {
    case ok
    case extensionOff
    case empty
    case entryNotFound
    case accessibilityRequired
    case blobMissing
}

public struct ClipboardQueueResponse: Codable, Equatable, Sendable {
    public let status: ClipboardQueueStatus
    public let items: [ClipboardQueueItem]
    public let item: ClipboardQueueItem?
    public let changed: Int

    public init(
        status: ClipboardQueueStatus, items: [ClipboardQueueItem] = [],
        item: ClipboardQueueItem? = nil, changed: Int = 0
    ) {
        self.status = status
        self.items = items
        self.item = item
        self.changed = changed
    }
}

public enum ClipboardQueueBridge {
    public static let actionKey = "action"
    public static let entryIDKey = "entryID"
    public static let requestIDKey = "requestID"
    public static let responseKey = "response"

    public static func responseName(requestID: String) -> Notification.Name {
        Notification.Name("com.pulkit.edith.clipboardQueueResponse.\(requestID)")
    }

    public static func encode(_ response: ClipboardQueueResponse) -> String {
        guard let data = try? JSONEncoder().encode(response) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> ClipboardQueueResponse? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClipboardQueueResponse.self, from: data)
    }
}
