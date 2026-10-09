import EdithExtensionSupport
import CryptoKit
import Foundation

public struct CodeStatsCandidate: Equatable, Sendable {
    public var sha: String
    public var header: String

    public init(sha: String, header: String) {
        self.sha = sha
        self.header = header
    }
}

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

    public init(root: URL = ExtensionData.root) {
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
        var byteCount = 0
        var fileCount = 0
        for owner in owners.prefix(CodeStatsOwnedIO.maximumCacheFiles) {
            let files =
                (try? fileManager.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil))
                ?? []
            for file in files.prefix(CodeStatsOwnedIO.maximumCacheFiles)
            where file.pathExtension == "json" {
                guard fileCount < CodeStatsOwnedIO.maximumCacheFiles else { return caches }
                fileCount += 1
                guard
                    let data = CodeStatsOwnedIO.read(
                        file, root: root,
                        limit: min(
                            CodeStatsOwnedIO.maximumFileBytes,
                            CodeStatsOwnedIO.maximumCacheBytes - byteCount)),
                    let cache = try? JSONDecoder().decode(
                        CodeStatsRepositoryCache.self, from: data),
                    cache.version == CodeStatsRepositoryCache.currentVersion,
                    CodeStatsOwnedIO.validRepository(cache.repository),
                    file.standardizedFileURL == cacheFile(for: cache.repository).standardizedFileURL
                else { continue }
                byteCount += data.count
                caches[cache.repository] = cache
            }
        }
        return caches
    }

    public func save(_ cache: CodeStatsRepositoryCache) throws {
        guard CodeStatsOwnedIO.validRepository(cache.repository) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try CodeStatsOwnedIO.write(
            JSONEncoder().encode(cache), to: cacheFile(for: cache.repository), root: root)
    }

    public func removeCaches(except kept: Set<String>) {
        for repository in loadCaches().keys where !kept.contains(repository) {
            try? FileManager.default.removeItem(at: cacheFile(for: repository))
        }
    }

    public func loadReports() -> [CodeStatsReport] {
        guard let data = CodeStatsOwnedIO.read(reportsFile, root: root) else { return [] }
        return (try? JSONDecoder().decode([CodeStatsReport].self, from: data)) ?? []
    }

    public func saveReports(_ reports: [CodeStatsReport]) throws {
        try CodeStatsOwnedIO.write(JSONEncoder().encode(reports), to: reportsFile, root: root)
    }

    public func loadFacts() -> CodeStatsFactTable? {
        guard let data = CodeStatsOwnedIO.read(factsFile, root: root) else { return nil }
        return try? JSONDecoder().decode(CodeStatsFactTable.self, from: data)
    }

    public func saveFacts(_ table: CodeStatsFactTable) throws {
        try CodeStatsOwnedIO.write(JSONEncoder().encode(table), to: factsFile, root: root)
    }

    public func loadState() -> CodeStatsState {
        guard let data = CodeStatsOwnedIO.read(stateFile, root: root) else {
            return CodeStatsState()
        }
        return (try? JSONDecoder().decode(CodeStatsState.self, from: data)) ?? CodeStatsState()
    }

    public func saveState(_ state: CodeStatsState) throws {
        try CodeStatsOwnedIO.write(JSONEncoder().encode(state), to: stateFile, root: root)
    }
}
