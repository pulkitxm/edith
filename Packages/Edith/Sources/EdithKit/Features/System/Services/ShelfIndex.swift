import Foundation

public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let addedAt: Date
    public var position: CGPoint?

    public init(id: UUID, name: String, addedAt: Date, position: CGPoint? = nil) {
        self.id = id
        self.name = name
        self.addedAt = addedAt
        self.position = position
    }
}

public enum ShelfKeepDuration: String, CaseIterable, Sendable {
    case forever, oneHour, oneDay, oneWeek, oneMonth

    public var seconds: TimeInterval? {
        switch self {
        case .forever: return nil
        case .oneHour: return 3600
        case .oneDay: return 86400
        case .oneWeek: return 604_800
        case .oneMonth: return 2_592_000
        }
    }
}

public enum ShelfExpiry {
    public static func isExpired(addedAt: Date, keep: ShelfKeepDuration, now: Date = Date())
        -> Bool
    {
        guard let seconds = keep.seconds else { return false }
        return now.timeIntervalSince(addedAt) >= seconds
    }
}

public enum ShelfIndex {
    nonisolated(unsafe) public static var root: URL =
        AppData.supportDir.appendingPathComponent("Shelf")

    public static func indexFile(in root: URL = ShelfIndex.root) -> URL {
        root.appendingPathComponent(".index.json")
    }

    public static func load(from root: URL = ShelfIndex.root) -> [ShelfItem] {
        guard let data = try? Data(contentsOf: indexFile(in: root)) else { return [] }
        return (try? JSONDecoder().decode([ShelfItem].self, from: data)) ?? []
    }

    public static func save(_ items: [ShelfItem], to root: URL = ShelfIndex.root) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: indexFile(in: root), options: .atomic)
    }

    public static func fileURL(for item: ShelfItem, in root: URL = ShelfIndex.root) -> URL {
        root.appendingPathComponent(item.name)
    }
}
