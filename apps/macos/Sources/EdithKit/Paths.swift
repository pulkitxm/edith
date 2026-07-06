import Foundation

public enum AppData {
    public static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0
        ]
        .appendingPathComponent("Edith")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let cloudDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Edith")

    public static var cloudAvailable: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }
}

public enum Repo {
    public static var devRoot: URL? {
        SharedDefaults.store.string(forKey: "repoPath").map { URL(fileURLWithPath: $0) }
    }

    public static var dataDir: URL {
        devRoot?.appendingPathComponent("apps/dashboard/data")
            ?? AppData.supportDir.appendingPathComponent("data")
    }
    public static var usageJSON: URL { dataDir.appendingPathComponent("usage.json") }
    public static var limitsJSONL: URL { dataDir.appendingPathComponent("limits-history.jsonl") }
    public static var musicDir: URL {
        devRoot?.appendingPathComponent("local/music")
            ?? AppData.supportDir.appendingPathComponent("music")
    }
}
