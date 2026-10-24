import Foundation

public enum LimitsSnapshotCache {
    public static var url: URL { Repo.dataDir.appendingPathComponent("limits-snapshot.json") }

    public static func load(url: URL = url) -> LimitsTopicSnapshot? {
        guard
            let data = try? UsageDataFiles.readRegularFile(
                at: url, maximumBytes: 4 * 1_024 * 1_024)
        else { return nil }
        return try? JSONDecoder().decode(LimitsTopicSnapshot.self, from: data)
    }

    public static func save(_ snapshot: LimitsTopicSnapshot, url: URL = url) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UsageDataFiles.write(try JSONEncoder().encode(snapshot), to: url)
    }
}
