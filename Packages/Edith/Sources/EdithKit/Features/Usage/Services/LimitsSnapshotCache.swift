import Foundation

public enum LimitsSnapshotCache {
    public static var url: URL { AppData.supportDir.appendingPathComponent("limits-snapshot.json") }

    public static func load(url: URL = url) -> LimitsTopicSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LimitsTopicSnapshot.self, from: data)
    }

    public static func save(_ snapshot: LimitsTopicSnapshot, url: URL = url) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
