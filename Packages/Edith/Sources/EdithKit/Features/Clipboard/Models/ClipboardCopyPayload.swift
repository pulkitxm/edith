import Foundation

public struct ClipboardCopyRequest: Codable, Sendable {
    public let id: String
    public let plainTextOnly: Bool

    public init(id: String, plainTextOnly: Bool) {
        self.id = id
        self.plainTextOnly = plainTextOnly
    }
}

public struct ClipboardCopyPayload: Codable, Sendable {
    public let entry: ClipboardEntry
    public let data: Data
    public let text: String?
    public let urls: [URL]?
    public let plainTextOnly: Bool

    public init(entry: ClipboardEntry, data: Data, text: String?, urls: [URL]?, plainTextOnly: Bool)
    {
        self.entry = entry
        self.data = data
        self.text = text
        self.urls = urls
        self.plainTextOnly = plainTextOnly
    }
}

public struct ClipboardInspection: Codable, Sendable {
    public let entries: Int
    public let missingPayloads: Int

    public init(entries: Int, missingPayloads: Int) {
        self.entries = entries
        self.missingPayloads = missingPayloads
    }
}
