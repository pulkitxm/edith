import EdithKit
import Foundation

struct ShelfItem: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let addedAt: Date
}

enum ShelfKeepDuration: String, CaseIterable {
    case forever, oneHour, oneDay, oneWeek, oneMonth

    var seconds: TimeInterval? {
        switch self {
        case .forever: return nil
        case .oneHour: return 3600
        case .oneDay: return 86400
        case .oneWeek: return 604_800
        case .oneMonth: return 2_592_000
        }
    }
}

enum ShelfExpiry {
    static func isExpired(addedAt: Date, keep: ShelfKeepDuration, now: Date = Date()) -> Bool {
        guard let seconds = keep.seconds else { return false }
        return now.timeIntervalSince(addedAt) >= seconds
    }
}

@MainActor
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    private let root: URL

    init(root: URL = AppData.supportDir.appendingPathComponent("Shelf")) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        items = (try? JSONDecoder().decode([ShelfItem].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func directory(for item: ShelfItem) -> URL { root.appendingPathComponent(item.id.uuidString) }
    func fileURL(for item: ShelfItem) -> URL {
        directory(for: item).appendingPathComponent(item.name)
    }

    @discardableResult
    func addCopy(of source: URL) -> ShelfItem? {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString)
        let name = source.lastPathComponent
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        let item = ShelfItem(id: id, name: name, addedAt: Date())
        items.append(item)
        save()
        return item
    }

    @discardableResult
    func addText(_ text: String) -> ShelfItem? {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString)
        let name = "Dropped Text.txt"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        let item = ShelfItem(id: id, name: name, addedAt: Date())
        items.append(item)
        save()
        return item
    }

    @discardableResult
    func adopt(fileAt url: URL, id: UUID) -> ShelfItem {
        let item = ShelfItem(id: id, name: url.lastPathComponent, addedAt: Date())
        items.append(item)
        save()
        return item
    }

    func promiseDestination(id: UUID) -> URL {
        let dir = root.appendingPathComponent(id.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func discardPromiseDestination(id: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }

    func remove(_ item: ShelfItem) {
        try? FileManager.default.removeItem(at: directory(for: item))
        items.removeAll { $0.id == item.id }
        save()
    }

    func purgeExpired(keep: ShelfKeepDuration, now: Date = Date()) {
        let expired = items.filter {
            ShelfExpiry.isExpired(addedAt: $0.addedAt, keep: keep, now: now)
        }
        guard !expired.isEmpty else { return }
        for item in expired { try? FileManager.default.removeItem(at: directory(for: item)) }
        let expiredIDs = Set(expired.map(\.id))
        items.removeAll { expiredIDs.contains($0.id) }
        save()
    }
}
