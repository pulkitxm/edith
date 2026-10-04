import Foundation

public struct CodeStatsRepository: Codable, Equatable, Hashable, Sendable {
    public let fullName: String
    public let path: String
    public let isBare: Bool

    public init(fullName: String, path: String, isBare: Bool) {
        self.fullName = fullName
        self.path = path
        self.isBare = isBare
    }
}

public enum CodeStatsRepositoryDiscovery {
    public static func mirrorURL(root: URL, fullName: String) -> URL {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return root.appendingPathComponent(parts.first ?? fullName, isDirectory: true)
            .appendingPathComponent((parts.count > 1 ? parts[1] : fullName) + ".git")
    }

    static let stagingMarker = ".git.partial-"

    public static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            "." + destination.deletingPathExtension().lastPathComponent + stagingMarker
                + UUID().uuidString)
    }

    static func isStaging(_ name: String) -> Bool {
        guard name.hasPrefix("."), let marker = name.range(of: stagingMarker, options: .backwards)
        else { return false }
        return UUID(uuidString: String(name[marker.upperBound...])) != nil
    }

    @discardableResult
    public static func removeAbandonedStaging(
        root: URL, fileManager: FileManager = .default
    ) -> Int {
        var removed = 0
        for owner in visibleDirectories(in: root, fileManager: fileManager) {
            let children =
                (try? fileManager.contentsOfDirectory(
                    at: owner, includingPropertiesForKeys: nil)) ?? []
            for child in children where isStaging(child.lastPathComponent) {
                if (try? fileManager.removeItem(at: child)) != nil { removed += 1 }
            }
        }
        return removed
    }

    public static func discover(
        root: URL, fileManager: FileManager = .default
    ) -> [CodeStatsRepository] {
        var found: [String: CodeStatsRepository] = [:]
        for owner in visibleDirectories(in: root, fileManager: fileManager) {
            for child in visibleDirectories(in: owner, fileManager: fileManager) {
                let name = child.lastPathComponent
                let repository: CodeStatsRepository
                if name.hasSuffix(".git"), isBareRepository(child, fileManager: fileManager) {
                    repository = CodeStatsRepository(
                        fullName: owner.lastPathComponent + "/" + name.dropLast(4),
                        path: child.path, isBare: true)
                } else if fileManager.fileExists(atPath: child.appendingPathComponent(".git").path)
                {
                    repository = CodeStatsRepository(
                        fullName: owner.lastPathComponent + "/" + name, path: child.path,
                        isBare: false)
                } else {
                    continue
                }
                let key = repository.fullName.lowercased()
                if found[key]?.isBare != true { found[key] = repository }
            }
        }
        return found.values.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
    }

    private static func isBareRepository(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("HEAD").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("objects").path)
    }

    private static func visibleDirectories(in url: URL, fileManager: FileManager) -> [URL] {
        let children =
            (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        return children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
