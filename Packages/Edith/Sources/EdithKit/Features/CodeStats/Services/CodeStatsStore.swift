import Foundation

public struct CodeStatsRepositoryCache: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var repository: String
    public var refsFingerprint: String
    public var identityFingerprint: String
    public var commits: [CodeStatsCommit]

    public init(
        repository: String, refsFingerprint: String, identityFingerprint: String,
        commits: [CodeStatsCommit]
    ) {
        version = Self.currentVersion
        self.repository = repository
        self.refsFingerprint = refsFingerprint
        self.identityFingerprint = identityFingerprint
        self.commits = commits
    }

    public func freshCommits(refs: String, identity: String) -> [CodeStatsCommit]? {
        refsFingerprint == refs && identityFingerprint == identity ? commits : nil
    }
}

public struct CodeStatsStore: Sendable {
    public let root: URL

    public init(root: URL = DataRoot.codeStats) {
        self.root = root
    }

    private var repositoriesFolder: URL { root.appendingPathComponent("repositories") }
    private var reportsFile: URL { root.appendingPathComponent("reports.json") }

    private func cacheFile(for repository: String) -> URL {
        repository.split(separator: "/").reduce(repositoriesFolder) {
            $0.appendingPathComponent(String($1))
        }.appendingPathExtension("json")
    }

    public func loadCaches() -> [String: CodeStatsRepositoryCache] {
        let fileManager = FileManager.default
        let owners =
            (try? fileManager.contentsOfDirectory(
                at: repositoriesFolder, includingPropertiesForKeys: nil)) ?? []
        var caches: [String: CodeStatsRepositoryCache] = [:]
        for owner in owners {
            let files =
                (try? fileManager.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil))
                ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                    let cache = try? JSONDecoder().decode(
                        CodeStatsRepositoryCache.self, from: data),
                    cache.version == CodeStatsRepositoryCache.currentVersion
                else { continue }
                caches[cache.repository] = cache
            }
        }
        return caches
    }

    public func save(_ cache: CodeStatsRepositoryCache) throws {
        let file = cacheFile(for: cache.repository)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: file, options: .atomic)
    }

    public func removeCaches(except kept: Set<String>) {
        for repository in loadCaches().keys where !kept.contains(repository) {
            try? FileManager.default.removeItem(at: cacheFile(for: repository))
        }
    }

    public func loadReports() -> [CodeStatsReport] {
        guard let data = try? Data(contentsOf: reportsFile) else { return [] }
        return (try? JSONDecoder().decode([CodeStatsReport].self, from: data)) ?? []
    }

    public func saveReports(_ reports: [CodeStatsReport]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(reports).write(to: reportsFile, options: .atomic)
    }
}
