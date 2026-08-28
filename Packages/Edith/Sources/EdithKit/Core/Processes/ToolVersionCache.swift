import Foundation

public enum ToolVersionCache {
    public struct Stamp: Codable, Equatable, Sendable {
        public let resolvedPath: String
        public let size: Int64
        public let modified: Double
        public let systemNumber: UInt64
        public let systemFileNumber: UInt64
        public let version: String
    }

    struct Identity: Equatable, Sendable {
        let resolvedPath: String
        let size: Int64
        let modified: Double
        let systemNumber: UInt64
        let systemFileNumber: UInt64
    }

    nonisolated(unsafe) public static var storeURL: URL = AppData.supportDir
        .appendingPathComponent("tool-versions.json")

    public static func stamp(for executable: URL) -> (size: Int64, modified: Double)? {
        guard let identity = identity(for: executable) else { return nil }
        return (identity.size, identity.modified)
    }

    static func identity(for executable: URL) -> Identity? {
        let resolved = executable.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? Int64,
            let modified = attributes[.modificationDate] as? Date,
            let systemNumber = attributes[.systemNumber] as? NSNumber,
            let systemFileNumber = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return Identity(
            resolvedPath: resolved.path,
            size: size,
            modified: modified.timeIntervalSince1970,
            systemNumber: systemNumber.uint64Value,
            systemFileNumber: systemFileNumber.uint64Value)
    }

    public static func cached(for executable: URL) -> String? {
        guard let current = identity(for: executable), let entry = load()[executable.path],
            entry.resolvedPath == current.resolvedPath,
            entry.size == current.size,
            abs(entry.modified - current.modified) < 0.001
                && entry.systemNumber == current.systemNumber
                && entry.systemFileNumber == current.systemFileNumber
        else { return nil }
        return entry.version
    }

    public static func remember(_ version: String, for executable: URL) {
        guard let current = identity(for: executable) else { return }
        var entries = load()
        entries[executable.path] = Stamp(
            resolvedPath: current.resolvedPath,
            size: current.size,
            modified: current.modified,
            systemNumber: current.systemNumber,
            systemFileNumber: current.systemFileNumber,
            version: version)
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
