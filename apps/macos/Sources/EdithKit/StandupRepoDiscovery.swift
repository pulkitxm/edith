import Foundation

public enum StandupRepoDiscovery {
    public static func discover(
        roots: [String], depth: Int = 2, fileManager: FileManager = .default
    ) -> [String] {
        var found: [String] = []
        for root in roots {
            found.append(contentsOf: scan(root, depth: depth, fileManager: fileManager))
        }
        return found
    }

    private static func scan(_ path: String, depth: Int, fileManager: FileManager) -> [String] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        if fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
            return [path]
        }
        guard depth > 0 else { return [] }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return [] }
        var found: [String] = []
        for entry in entries {
            let childPath = (path as NSString).appendingPathComponent(entry)
            found.append(contentsOf: scan(childPath, depth: depth - 1, fileManager: fileManager))
        }
        return found
    }
}
