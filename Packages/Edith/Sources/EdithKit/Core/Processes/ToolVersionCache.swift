import Foundation

public enum ToolVersionCache {
    public struct Stamp: Codable, Equatable, Sendable {
        public let size: Int64
        public let modified: Double
        public let version: String
    }

    nonisolated(unsafe) public static var storeURL: URL = AppData.supportDir
        .appendingPathComponent("tool-versions.json")

    public static func stamp(for executable: URL) -> (size: Int64, modified: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
            let size = attributes[.size] as? Int64,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return (size, modified.timeIntervalSince1970)
    }

    public static func cached(for executable: URL) -> String? {
        guard let current = stamp(for: executable), let entry = load()[executable.path],
            entry.size == current.size, abs(entry.modified - current.modified) < 0.001
        else { return nil }
        return entry.version
    }

    public static func remember(_ version: String, for executable: URL) {
        guard let current = stamp(for: executable) else { return }
        var entries = load()
        entries[executable.path] = Stamp(
            size: current.size, modified: current.modified, version: version)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    public static func forget(_ executable: URL) {
        var entries = load()
        guard entries.removeValue(forKey: executable.path) != nil,
            let data = try? JSONEncoder().encode(entries)
        else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    static func load() -> [String: Stamp] {
        guard let data = try? Data(contentsOf: storeURL),
            let entries = try? JSONDecoder().decode([String: Stamp].self, from: data)
        else { return [:] }
        return entries
    }
}
