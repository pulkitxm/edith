import CryptoKit
import Foundation

public struct CodeStatsRefState: Equatable, Sendable {
    public var fingerprint: String
    public var tips: [String]

    public init(lines: [String]) {
        var hasher = SHA256()
        for line in lines { hasher.update(data: Data((line + "\n").utf8)) }
        fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        tips = Array(Set(lines.compactMap { $0.split(separator: " ").first.map(String.init) }))
            .sorted()
    }
}

public struct CodeStatsRepositoryCache: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var repository: String
    public var refsFingerprint: String
    public var identityFingerprint: String
    public var tips: [String]
    public var integrated: [String]
    public var authors: [CodeStatsAuthor]
    public var commits: [CodeStatsCommit]

    public init(
        repository: String, refsFingerprint: String, identityFingerprint: String,
        tips: [String] = [], integrated: [String] = [], authors: [CodeStatsAuthor] = [],
        commits: [CodeStatsCommit]
    ) {
        version = Self.currentVersion
        self.repository = repository
        self.refsFingerprint = refsFingerprint
        self.identityFingerprint = identityFingerprint
        self.tips = tips
        self.integrated = integrated
        self.authors = authors
        self.commits = commits
    }

    public func freshCommits(refs: String, identity: String) -> [CodeStatsCommit]? {
        refsFingerprint == refs && identityFingerprint == identity ? commits : nil
    }

    public func extendable(identity: String) -> Bool {
        identityFingerprint == identity && !tips.isEmpty
    }
}

public struct CodeStatsStore: Sendable {
    public let root: URL

    public init(root: URL = DataRoot.codeStats) {
        self.root = root
    }

    private var repositoriesFolder: URL { root.appendingPathComponent("repositories") }
    private var reportsFile: URL { root.appendingPathComponent("reports.json") }
    private var factsFile: URL { root.appendingPathComponent("facts.json") }
    private var stateFile: URL { root.appendingPathComponent("state.json") }

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

    public func loadFacts() -> CodeStatsFactTable? {
        guard let data = try? Data(contentsOf: factsFile) else { return nil }
        return try? JSONDecoder().decode(CodeStatsFactTable.self, from: data)
    }

    public func saveFacts(_ table: CodeStatsFactTable) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(table).write(to: factsFile, options: .atomic)
    }

    public func loadState() -> CodeStatsState {
        guard let data = try? Data(contentsOf: stateFile) else { return CodeStatsState() }
        return (try? JSONDecoder().decode(CodeStatsState.self, from: data)) ?? CodeStatsState()
    }

    public func saveState(_ state: CodeStatsState) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }
}
