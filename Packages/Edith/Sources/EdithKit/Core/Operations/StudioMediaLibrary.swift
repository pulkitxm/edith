import Foundation

public struct StudioMediaItem: Identifiable, Hashable, Codable, Sendable {
    public let url: URL
    public var addedAt: Date

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, addedAt: Date = Date()) {
        self.url = url
        self.addedAt = addedAt
    }
}

public enum StudioMediaLibrary {
    public static func list(defaults: UserDefaults = SharedDefaults.store) throws
        -> [StudioMediaItem]
    {
        defaults.synchronize()
        guard let data = defaults.data(forKey: AppStorageKeys.Studio.library) else { return [] }
        return try JSONDecoder().decode([StudioMediaItem].self, from: data)
    }

    @discardableResult
    public static func add(_ urls: [URL], defaults: UserDefaults = SharedDefaults.store) throws
        -> [StudioMediaItem]
    {
        var items = try list(defaults: defaults)
        var known = Set(items.map(\.url))
        let added = expand(urls).filter { known.insert($0).inserted }.map {
            StudioMediaItem(url: $0)
        }
        items.insert(contentsOf: added, at: 0)
        try save(items, defaults: defaults)
        return items
    }

    @discardableResult
    public static func remove(_ urls: Set<URL>, defaults: UserDefaults = SharedDefaults.store)
        throws
        -> [StudioMediaItem]
    {
        let normalized = Set(urls.map(\.standardizedFileURL))
        let items = try list(defaults: defaults).filter {
            !normalized.contains($0.url.standardizedFileURL)
        }
        try save(items, defaults: defaults)
        return items
    }

    public static func clear(
        defaults: UserDefaults = SharedDefaults.store, recent: Bool = false,
        recentURL: URL = DataRoot.studio.appendingPathComponent("recent.json")
    ) throws {
        if recent, FileManager.default.fileExists(atPath: recentURL.path) {
            try Data("[]".utf8).write(to: recentURL, options: .atomic)
        }
        defaults.removeObject(forKey: AppStorageKeys.Studio.library)
        defaults.synchronize()
        IPC.post(IPC.Name.studioMediaLibraryChanged)
    }

    public static func save(
        _ items: [StudioMediaItem], defaults: UserDefaults = SharedDefaults.store
    )
        throws
    {
        defaults.set(try JSONEncoder().encode(items), forKey: AppStorageKeys.Studio.library)
        defaults.synchronize()
        IPC.post(IPC.Name.studioMediaLibraryChanged)
    }

    public static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let manager = FileManager.default
        for url in urls {
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            guard directory.boolValue else {
                result.append(url.standardizedFileURL)
                continue
            }
            let enumerator = manager.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let item = enumerator?.nextObject() as? URL, result.count < 500 {
                if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    result.append(item.standardizedFileURL)
                }
            }
        }
        return result
    }
}
