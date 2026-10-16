import EdithCore
import Foundation

public struct StorageAreaDefinition: Sendable {
    public let id: String
    public let title: String
    public let relativePaths: [String]
}

public enum StorageAreaCatalog {
    public static let areas: [StorageAreaDefinition] = [
        .init(id: "machines", title: "Fleet", relativePaths: ["machines"]),
        .init(id: "database", title: "Database", relativePaths: ["database"]),
        .init(id: "clipboard", title: "Clipboard", relativePaths: ["clipboard"]),
        .init(id: "usage", title: "Usage", relativePaths: ["data"]),
        .init(id: "attention", title: "Attention", relativePaths: ["attention"]),
        .init(
            id: "music", title: "Music",
            relativePaths: ["music", "thumbnails", "music-library-index.json"]),
        .init(id: "studio", title: "Studio", relativePaths: ["studio"]),
        .init(
            id: "videoProjects", title: "Video projects and recordings",
            relativePaths: ["video-projects"]),
        .init(id: "virtualCamera", title: "Virtual Camera", relativePaths: ["virtual-camera"]),
        .init(
            id: "seoAudit", title: "Site Audit",
            relativePaths: ["SEOAudit", "Cache/SEOAudit", "seo"]),
        .init(id: "codeStats", title: "Code Stats", relativePaths: ["code-stats"]),
        .init(id: "latex", title: "LaTeX", relativePaths: ["latex"]),
        .init(id: "plugins", title: "Plugins", relativePaths: ["plugins"]),
        .init(id: "shelf", title: "Shelf", relativePaths: ["Shelf"]),
        .init(id: "tools", title: "Command line tools", relativePaths: ["bin"]),
        .init(id: "snapshots", title: "Snapshots", relativePaths: ["Snapshots"]),
        .init(id: "notchBrowser", title: "Notch browser", relativePaths: ["notch-browser"]),
    ]
}

public struct StorageArea: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let roots: [URL]
    public let scopeIDs: [String]

    public func bytes(in measurement: StorageMeasurement) -> StorageBytes {
        measurement.sum(scopeIDs)
    }
}

public struct StorageCategory: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let scopeIDs: [String]

    public func bytes(in measurement: StorageMeasurement) -> StorageBytes {
        measurement.sum(scopeIDs)
    }
}

public struct StorageItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let roots: [URL]
    public let scopeIDs: [String]

    public func bytes(in measurement: StorageMeasurement) -> StorageBytes {
        measurement.sum(scopeIDs)
    }
}

public struct StorageUsage: Identifiable, Sendable {
    public let item: StorageItem
    public let bytes: StorageBytes
    public var id: String { item.id }
}

public struct StorageInventory: Sendable {
    public static let databaseFileName = "edith.sqlite"

    public let scopes: [StorageScope]
    public let areas: [StorageArea]
    public let categories: [StorageCategory]
    public let items: [StorageItem]
    public let appVersion: String?

    public init(
        appBundle: URL = Bundle.main.bundleURL,
        appVersion: String?,
        support: URL = DataRoot.support,
        caches: URL = DataRoot.caches,
        logs: URL = DataRoot.logs,
        preferencesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences"),
        preferenceSuites: [String] = [
            SharedDefaults.activeSuiteName, AppBuildIdentity.application,
        ],
        selectedMusicDirectory: URL? = Repo.selectedMusicDirectory(),
        fileManager: FileManager = .default
    ) {
        var scopes: [StorageScope] = [
            .init(id: "app", root: appBundle, expected: true),
            .init(id: "support", root: support),
            .init(id: "tasks", root: support.appendingPathComponent("Tasks")),
            .init(id: "caches", root: caches),
            .init(id: "runtime", root: caches.appendingPathComponent("Runtime")),
            .init(id: "logs", root: logs),
        ]
        let storeNames =
            [Self.databaseFileName, Self.databaseFileName + "-wal", Self.databaseFileName + "-shm"]
            + ((try? fileManager.contentsOfDirectory(atPath: support.path)) ?? [])
            .filter { $0.hasPrefix(Self.databaseFileName + ".pre-") }.sorted()
        let storeIDs = storeNames.enumerated().map { "agent-store:" + String($0.offset) }
        for (id, name) in zip(storeIDs, storeNames) {
            scopes.append(.init(id: id, root: support.appendingPathComponent(name)))
        }
        var preferenceIDs: [String] = []
        for suite in preferenceSuites {
            let id = "preferences:" + suite
            guard !preferenceIDs.contains(id) else { continue }
            preferenceIDs.append(id)
            scopes.append(
                .init(id: id, root: preferencesDirectory.appendingPathComponent(suite + ".plist")))
        }
        var areas: [StorageArea] = []
        for definition in StorageAreaCatalog.areas {
            let roots = definition.relativePaths.map { support.appendingPathComponent($0) }
            let ids = roots.indices.map { "area:\(definition.id):\($0)" }
            for (id, root) in zip(ids, roots) { scopes.append(.init(id: id, root: root)) }
            areas.append(
                StorageArea(id: definition.id, title: definition.title, roots: roots, scopeIDs: ids)
            )
        }
        let selectedID = "music-selected-directory"
        if let selected = selectedMusicDirectory,
            !Self.contains(support.path, selected.path),
            !Self.contains(
                support.standardizedFileURL.path, selected.standardizedFileURL.path),
            !scopes.contains(where: {
                $0.root.standardizedFileURL == selected.standardizedFileURL
            })
        {
            scopes.append(.init(id: selectedID, root: selected))
        }
        self.scopes = scopes
        self.areas = areas
        self.appVersion = appVersion
        let categories: [StorageCategory] = [
            .init(id: "app", title: "Edith app", scopeIDs: ["app"]),
            .init(id: "feature-data", title: "Feature data", scopeIDs: areas.flatMap(\.scopeIDs)),
            .init(
                id: "selected-music-directory",
                title: "Music folder outside Edith",
                scopeIDs: scopes.contains { $0.id == selectedID } ? [selectedID] : []),
            .init(
                id: "store", title: "Database and background tasks",
                scopeIDs: storeIDs + ["tasks"]),
            .init(id: "cache", title: "Caches", scopeIDs: ["caches", "runtime"]),
            .init(
                id: "logs-preferences", title: "Logs and settings",
                scopeIDs: ["logs"] + preferenceIDs),
            .init(
                id: "other", title: "Other app data",
                scopeIDs: ["support"]),
        ]
        self.categories = categories
        let scopeRoots = Dictionary(uniqueKeysWithValues: scopes.map { ($0.id, $0.root) })
        items =
            areas.map {
                StorageItem(id: $0.id, title: $0.title, roots: $0.roots, scopeIDs: $0.scopeIDs)
            }
            + categories.filter { $0.id != "feature-data" && !$0.scopeIDs.isEmpty }.map {
                StorageItem(
                    id: $0.id, title: $0.title, roots: $0.scopeIDs.compactMap { scopeRoots[$0] },
                    scopeIDs: $0.scopeIDs)
            }
    }

    public func usage(in measurement: StorageMeasurement) -> [StorageUsage] {
        items.map { StorageUsage(item: $0, bytes: $0.bytes(in: measurement)) }
            .filter { $0.bytes.allocated > 0 || !$0.bytes.complete }
            .sorted {
                $0.bytes.allocated != $1.bytes.allocated
                    ? $0.bytes.allocated > $1.bytes.allocated : $0.item.title < $1.item.title
            }
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}
