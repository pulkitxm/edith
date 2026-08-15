import Foundation

public struct CompanionOutboxItem: Identifiable, Equatable, Sendable {
    public let url: URL
    public let recordedAt: Date

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, recordedAt: Date) {
        self.url = url
        self.recordedAt = recordedAt
    }
}

public struct CompanionOutboxDrain: Equatable, Sendable {
    public var sent: Int
    public var duplicates: Int
    public var failed: Int

    public init(sent: Int = 0, duplicates: Int = 0, failed: Int = 0) {
        self.sent = sent
        self.duplicates = duplicates
        self.failed = failed
    }

    public var isEmpty: Bool { sent == 0 && duplicates == 0 && failed == 0 }

    public var summary: String {
        var parts: [String] = []
        if sent > 0 { parts.append("\(sent) remembered") }
        if duplicates > 0 { parts.append("\(duplicates) already known") }
        if failed > 0 { parts.append("\(failed) still waiting") }
        return parts.joined(separator: ", ")
    }
}

public enum CompanionOutbox {
    public static var directory: URL {
        MachinePaths.root.appendingPathComponent("companion-outbox", isDirectory: true)
    }

    public static func keep(_ source: URL, in root: URL = directory) -> URL? {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    public static func waiting(in root: URL = directory) -> [CompanionOutboxItem] {
        let manager = FileManager.default
        guard
            let names = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return
            names
            .map { url in
                let created =
                    (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? Date.distantPast
                return CompanionOutboxItem(url: url, recordedAt: created)
            }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    public static func forget(_ item: CompanionOutboxItem) {
        try? FileManager.default.removeItem(at: item.url)
    }

    public static func drain(
        in root: URL = directory,
        send: (CompanionOutboxItem, Data) async throws -> String
    ) async -> CompanionOutboxDrain {
        var result = CompanionOutboxDrain()
        for item in waiting(in: root) {
            guard let data = try? Data(contentsOf: item.url) else {
                result.failed += 1
                continue
            }
            do {
                let status = try await send(item, data)
                if status == "duplicate" { result.duplicates += 1 } else { result.sent += 1 }
                forget(item)
            } catch {
                result.failed += 1
            }
        }
        return result
    }
}
