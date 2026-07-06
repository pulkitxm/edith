import EdithKit
import Foundation

struct ShelfItem: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let addedAt: Date
    var position: CGPoint?
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
        migrateLegacyIndex()
        load()
        migrateLegacyFolders()
    }

    private var indexURL: URL { root.appendingPathComponent(".index.json") }

    private func migrateLegacyIndex() {
        let legacy = root.appendingPathComponent("index.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: indexURL.path) else {
            return
        }
        try? fm.moveItem(at: legacy, to: indexURL)
    }

    private func migrateLegacyFolders() {
        let fm = FileManager.default
        var changed = false
        for (index, item) in items.enumerated() {
            let legacyDir = root.appendingPathComponent(item.id.uuidString)
            let legacyFile = legacyDir.appendingPathComponent(item.name)
            guard fm.fileExists(atPath: legacyFile.path) else { continue }
            let name = uniqueName(item.name)
            guard (try? fm.moveItem(at: legacyFile, to: root.appendingPathComponent(name))) != nil
            else { continue }
            try? fm.removeItem(at: legacyDir)
            items[index] = ShelfItem(
                id: item.id, name: name, addedAt: item.addedAt, position: item.position)
            changed = true
        }
        if changed { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        items = (try? JSONDecoder().decode([ShelfItem].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func fileURL(for item: ShelfItem) -> URL { root.appendingPathComponent(item.name) }

    private func uniqueName(_ proposed: String) -> String {
        let fm = FileManager.default
        var name = proposed
        var counter = 2
        let base = (proposed as NSString).deletingPathExtension
        let ext = (proposed as NSString).pathExtension
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return name
    }

    @discardableResult
    func addCopy(of source: URL) -> ShelfItem? {
        let name = uniqueName(source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name))
        } catch {
            return nil
        }
        let item = ShelfItem(id: UUID(), name: name, addedAt: Date())
        items.append(item)
        save()
        return item
    }

    @discardableResult
    func addText(_ text: String) -> ShelfItem? {
        let name = uniqueName("Dropped Text.txt")
        do {
            try text.write(
                to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        let item = ShelfItem(id: UUID(), name: name, addedAt: Date())
        items.append(item)
        save()
        return item
    }

    @discardableResult
    func adopt(fileAt url: URL, id: UUID) -> ShelfItem? {
        let name = uniqueName(url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: root.appendingPathComponent(name))
        } catch {
            discardPromiseDestination(id: id)
            return nil
        }
        discardPromiseDestination(id: id)
        let item = ShelfItem(id: id, name: name, addedAt: Date())
        items.append(item)
        save()
        return item
    }

    func promiseDestination(id: UUID) -> URL {
        let dir = root.appendingPathComponent(".incoming-\(id.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func discardPromiseDestination(id: UUID) {
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(".incoming-\(id.uuidString)"))
    }

    func item(forFileURL url: URL) -> ShelfItem? {
        let path = url.standardizedFileURL.path
        return items.first { fileURL(for: $0).standardizedFileURL.path == path }
    }

    func setPosition(_ position: CGPoint, for item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].position = position
        save()
    }

    func remove(_ item: ShelfItem) {
        try? FileManager.default.removeItem(at: fileURL(for: item))
        items.removeAll { $0.id == item.id }
        save()
    }

    func purgeExpired(keep: ShelfKeepDuration, now: Date = Date()) {
        let expired = items.filter {
            ShelfExpiry.isExpired(addedAt: $0.addedAt, keep: keep, now: now)
        }
        guard !expired.isEmpty else { return }
        for item in expired {
            try? FileManager.default.removeItem(at: fileURL(for: item))
        }
        let expiredIDs = Set(expired.map(\.id))
        items.removeAll { expiredIDs.contains($0.id) }
        save()
    }
}
