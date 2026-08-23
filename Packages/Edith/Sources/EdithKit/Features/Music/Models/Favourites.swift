import Foundation

public enum Favourites {
    public static let key = "musicFavourites"

    public static var paths: [String] {
        SharedDefaults.store.stringArray(forKey: key) ?? []
    }

    public static func contains(_ relativePath: String) -> Bool {
        paths.contains(relativePath)
    }

    @discardableResult
    public static func toggle(_ relativePath: String) -> Bool {
        let wanted = !contains(relativePath)
        _ = set(relativePath, isFavourite: wanted)
        return wanted
    }

    @discardableResult
    public static func set(_ relativePath: String, isFavourite: Bool) -> Bool {
        var list = paths
        let existing = list.firstIndex(of: relativePath)
        guard (existing != nil) != isFavourite else { return false }
        if let existing {
            list.remove(at: existing)
        } else {
            list.append(relativePath)
        }
        save(list)
        return true
    }

    public static func repoint(from old: String, to new: String) {
        var list = paths
        var changed = false
        for (index, path) in list.enumerated() {
            if path == old {
                list[index] = new
                changed = true
            } else if path.hasPrefix(old + "/") {
                list[index] = new + path.dropFirst(old.count)
                changed = true
            }
        }
        if changed { save(list) }
    }

    public static func tracks() -> [Track] {
        paths.compactMap { path in
            let url = TrackMeta.url(for: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Track(url: url, relativePath: path)
        }
    }

    private static func save(_ list: [String]) {
        SharedDefaults.store.set(list, forKey: key)
        IPC.post(IPC.Name.musicFavouritesChanged)
    }
}
