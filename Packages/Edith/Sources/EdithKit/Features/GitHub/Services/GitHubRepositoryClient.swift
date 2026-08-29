import EdithCore
import Foundation

public actor GitHubRepositoryClient {
    public typealias SendRequest = @Sendable (GitHubAPIRequest) async throws -> GitHubAPIResponse

    public static let shared = GitHubRepositoryClient()
    public static let defaultCacheFile = AppDirectories.current.cache
        .appendingPathComponent("GitHub/resources-v1.json")

    private let sendRequest: SendRequest
    private let cacheFile: URL?
    private var cache: [String: CacheRecord]?
    private var repositoryReferences: [RepositoryReferenceKey: [String]] = [:]
    private let cacheLimit = 24
    private let cacheLifetime: TimeInterval = 60 * 60 * 24 * 7

    public init(
        transport: GitHubCLITransport = GitHubCLITransport(),
        cacheFile: URL? = GitHubRepositoryClient.defaultCacheFile
    ) {
        sendRequest = { try await transport.send($0) }
        self.cacheFile = cacheFile
    }

    public init(cacheFile: URL? = nil, sendRequest: @escaping SendRequest) {
        self.sendRequest = sendRequest
        self.cacheFile = cacheFile
    }

    public func cachedResource(for route: GitHubRoute) -> GitHubRepositoryResource? {
        loadCacheIfNeeded()
        let key = route.url.absoluteString
        guard var record = cache?[key],
            Date().timeIntervalSince(record.storedAt) <= cacheLifetime
        else {
            cache?[key] = nil
            return nil
        }
        record.accessedAt = Date()
        cache?[key] = record
        return record.resource
    }

    public func load(_ route: GitHubRoute) async throws -> GitHubRepositoryResource {
        try Task.checkCancellation()
        let resource: GitHubRepositoryResource
        switch route.resource {
        case let .repository(repository):
            resource = .repository(
                try await repositoryOverview(host: route.host, repository: repository))
        case let .content(repository, kind, revisionPath, _, _):
            let location = try await contentLocation(
                host: route.host, repository: repository, revisionPath: revisionPath)
            if kind == .tree {
                resource = .directory(
                    try await directory(
                        host: route.host, repository: repository, revision: location.revision,
                        path: location.path))
            } else if kind == .blob || kind == .raw || kind == .blame {
                guard !location.path.isEmpty else {
                    throw GitHubRepositoryLoadError.invalidResponse(
                        "The GitHub URL does not include a file path.")
                }
                resource = .file(
                    try await file(
                        host: route.host, repository: repository, revision: location.revision,
                        path: location.path))
            } else {
                throw GitHubRepositoryLoadError.unsupportedRoute(
                    "This GitHub content type is not available natively yet.")
            }
        default:
            throw GitHubRepositoryLoadError.unsupportedRoute(
                "This GitHub screen is classified, but it is not part of repository browsing yet.")
        }
        try Task.checkCancellation()
        store(resource, for: route)
        return resource
    }

    private func repositoryOverview(
        host: GitHubHost, repository: GitHubRepositoryPath
    ) async throws -> GitHubRepositoryOverview {
        let metadata: RepositoryDTO = try await json(
            GitHubAPIRequest(
                host: host, endpoint: GitHubCLITransport.endpoint(repository: repository)))
        try Task.checkCancellation()
        let branches: [BranchDTO] = try await json(
            GitHubAPIRequest(
                host: host,
                endpoint: GitHubCLITransport.endpoint(repository: repository, suffix: ["branches"]),
                query: [("per_page", "40")]))
        try Task.checkCancellation()
        guard !branches.isEmpty else {
            guard let url = URL(string: metadata.htmlURL) else {
                throw GitHubRepositoryLoadError.invalidResponse(
                    "GitHub returned an invalid repository URL.")
            }
            return GitHubRepositoryOverview(
                repository: repository, description: metadata.description,
                isPrivate: metadata.isPrivate, isFork: metadata.isFork,
                isArchived: metadata.isArchived, defaultBranch: metadata.defaultBranch,
                stars: metadata.stars, forks: metadata.forks, openIssues: metadata.openIssues,
                language: metadata.language, license: metadata.license?.spdxID,
                topics: metadata.topics, updatedAt: Self.date(metadata.updatedAt), url: url,
                branches: [], latestCommit: nil, entries: [])
        }
        let commits: [CommitDTO] = try await json(
            GitHubAPIRequest(
                host: host,
                endpoint: GitHubCLITransport.endpoint(repository: repository, suffix: ["commits"]),
                query: [("sha", metadata.defaultBranch), ("per_page", "1")]))
        try Task.checkCancellation()
        let entries = try await contents(
            host: host, repository: repository, revision: metadata.defaultBranch, path: "")
        guard let url = URL(string: metadata.htmlURL) else {
            throw GitHubRepositoryLoadError.invalidResponse(
                "GitHub returned an invalid repository URL.")
        }
        return GitHubRepositoryOverview(
            repository: repository, description: metadata.description,
            isPrivate: metadata.isPrivate, isFork: metadata.isFork,
            isArchived: metadata.isArchived, defaultBranch: metadata.defaultBranch,
            stars: metadata.stars, forks: metadata.forks, openIssues: metadata.openIssues,
            language: metadata.language, license: metadata.license?.spdxID,
            topics: metadata.topics, updatedAt: Self.date(metadata.updatedAt), url: url,
            branches: branches.map { GitHubBranchSummary(name: $0.name, sha: $0.commit.sha) },
            latestCommit: commits.first.map(Self.commit), entries: entries)
    }

    private func contentLocation(
        host: GitHubHost, repository: GitHubRepositoryPath, revisionPath: [String]
    ) async throws -> ContentLocation {
        guard let first = revisionPath.first else {
            throw GitHubRepositoryLoadError.invalidResponse(
                "The GitHub URL does not include a branch, tag, or commit.")
        }
        if revisionPath.count == 1 || first.contains("/") {
            return ContentLocation(
                revision: first, path: revisionPath.dropFirst().joined(separator: "/"))
        }
        let match = try await references(host: host, repository: repository)
            .compactMap { name -> (name: String, components: [String])? in
                let components = name.split(separator: "/").map(String.init)
                guard components.count <= revisionPath.count,
                    revisionPath.prefix(components.count).elementsEqual(components)
                else { return nil }
                return (name, components)
            }
            .max { $0.components.count < $1.components.count }
        guard let match else {
            return ContentLocation(
                revision: first, path: revisionPath.dropFirst().joined(separator: "/"))
        }
        return ContentLocation(
            revision: match.name,
            path: revisionPath.dropFirst(match.components.count).joined(separator: "/"))
    }

    private func references(
        host: GitHubHost, repository: GitHubRepositoryPath
    ) async throws -> [String] {
        let key = RepositoryReferenceKey(host: host, repository: repository)
        if let names = repositoryReferences[key] { return names }
        let branches = try await referenceNames(
            host: host, repository: repository, collection: "branches")
        let tags = try await referenceNames(
            host: host, repository: repository, collection: "tags")
        let names = branches + tags
        repositoryReferences[key] = names
        return names
    }

    private func referenceNames(
        host: GitHubHost, repository: GitHubRepositoryPath, collection: String
    ) async throws -> [String] {
        var names: [String] = []
        var page = 1
        while true {
            var query = [("per_page", "100")]
            if page > 1 { query.append(("page", String(page))) }
            let references: [ReferenceNameDTO] = try await json(
                GitHubAPIRequest(
                    host: host,
                    endpoint: GitHubCLITransport.endpoint(
                        repository: repository, suffix: [collection]),
                    query: query))
            names += references.map(\.name)
            guard references.count == 100 else { return names }
            page += 1
        }
    }

    private func directory(
        host: GitHubHost, repository: GitHubRepositoryPath, revision: String, path: String
    ) async throws -> GitHubDirectorySnapshot {
        GitHubDirectorySnapshot(
            repository: repository, revision: revision, path: path,
            entries: try await contents(
                host: host, repository: repository, revision: revision, path: path))
    }

    private func contents(
        host: GitHubHost, repository: GitHubRepositoryPath, revision: String, path: String
    ) async throws -> [GitHubRepositoryEntry] {
        var suffix = ["contents"]
        if !path.isEmpty { suffix += path.split(separator: "/").map(String.init) }
        let response = try await sendRequest(
            GitHubAPIRequest(
                host: host,
                endpoint: GitHubCLITransport.endpoint(repository: repository, suffix: suffix),
                query: [("ref", revision)], accept: "application/vnd.github.object+json"))
        try Task.checkCancellation()
        let values: [ContentDTO]
        if let array = try? Self.decoder().decode([ContentDTO].self, from: response.body) {
            values = array
        } else {
            values = try Self.decode(DirectoryDTO.self, from: response.body).entries
        }
        return values.map(Self.entry).sorted {
            if $0.kind == $1.kind {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if $0.kind == .directory { return true }
            if $1.kind == .directory { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func file(
        host: GitHubHost, repository: GitHubRepositoryPath, revision: String, path: String
    ) async throws -> GitHubFileSnapshot {
        let response = try await sendRequest(
            GitHubAPIRequest(
                host: host,
                endpoint: GitHubCLITransport.endpoint(
                    repository: repository,
                    suffix: ["contents"] + path.split(separator: "/").map(String.init)),
                query: [("ref", revision)], accept: "application/vnd.github.object+json",
                maximumOutputBytes: 6_000_000))
        try Task.checkCancellation()
        let value = try Self.decode(ContentDTO.self, from: response.body)
        let bytes = value.content.flatMap {
            Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
        }
        let presentation = Self.presentation(path: path, size: value.size, bytes: bytes)
        let text: String?
        if presentation == .text || presentation == .gitLFS, let bytes {
            text = String(data: bytes, encoding: .utf8)
        } else {
            text = nil
        }
        return GitHubFileSnapshot(
            repository: repository, revision: revision, path: path, sha: value.sha,
            size: value.size, text: text,
            downloadURL: value.downloadURL.flatMap(URL.init(string:)), presentation: presentation)
    }

    private func json<T: Decodable>(_ request: GitHubAPIRequest) async throws -> T {
        let response = try await sendRequest(request)
        try Task.checkCancellation()
        return try Self.decode(T.self, from: response.body)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder().decode(type, from: data)
        } catch {
            throw GitHubRepositoryLoadError.invalidResponse(
                "GitHub returned data that Edith could not decode.")
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func date(_ value: String?) -> Date? {
        value.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    private static func entry(_ value: ContentDTO) -> GitHubRepositoryEntry {
        GitHubRepositoryEntry(
            name: value.name, path: value.path,
            kind: GitHubRepositoryEntryKind(rawValue: value.type), size: value.size,
            sha: value.sha, url: value.htmlURL.flatMap(URL.init(string:)))
    }

    private static func commit(_ value: CommitDTO) -> GitHubCommitSummary {
        GitHubCommitSummary(
            sha: value.sha, message: value.commit.message,
            authorName: value.commit.author?.name ?? value.author?.login ?? "Unknown author",
            authorLogin: value.author?.login, authoredAt: date(value.commit.author?.date),
            url: value.htmlURL.flatMap(URL.init(string:)))
    }

    private static func presentation(
        path: String, size: Int, bytes: Data?
    ) -> GitHubFilePresentation {
        if size > 4_000_000 || bytes == nil { return .large }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ["mp3", "m4a", "wav", "aac", "flac", "ogg"].contains(ext) { return .audio }
        if ["mp4", "mov", "m4v", "webm"].contains(ext) { return .video }
        guard let bytes else { return .binary }
        if bytes.starts(with: Data("version https://git-lfs.github.com/spec/v1".utf8)) {
            return .gitLFS
        }
        if bytes.contains(0) || String(data: bytes, encoding: .utf8) == nil { return .binary }
        return .text
    }

    private func loadCacheIfNeeded() {
        guard cache == nil else { return }
        guard let cacheFile, let data = try? Data(contentsOf: cacheFile),
            let archive = try? JSONDecoder().decode(CacheArchive.self, from: data),
            archive.version == 1
        else {
            cache = [:]
            return
        }
        cache = Dictionary(uniqueKeysWithValues: archive.records.map { ($0.key, $0) })
    }

    private func store(_ resource: GitHubRepositoryResource, for route: GitHubRoute) {
        loadCacheIfNeeded()
        let now = Date()
        let key = route.url.absoluteString
        cache?[key] = CacheRecord(key: key, storedAt: now, accessedAt: now, resource: resource)
        guard let cacheFile, shouldPersist(resource) else { return }
        let records = Array(cache?.values ?? Dictionary<String, CacheRecord>().values).sorted {
            $0.accessedAt > $1.accessedAt
        }
        cache = Dictionary(uniqueKeysWithValues: records.prefix(cacheLimit).map { ($0.key, $0) })
        do {
            try FileManager.default.createDirectory(
                at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let archive = CacheArchive(version: 1, records: Array(records.prefix(cacheLimit)))
            try JSONEncoder().encode(archive).write(to: cacheFile, options: .atomic)
        } catch {}
    }

    private func shouldPersist(_ resource: GitHubRepositoryResource) -> Bool {
        guard case let .file(file) = resource else { return true }
        return file.size <= 256_000
    }
}

private struct CacheArchive: Codable {
    let version: Int
    let records: [CacheRecord]
}

private struct CacheRecord: Codable {
    let key: String
    let storedAt: Date
    var accessedAt: Date
    let resource: GitHubRepositoryResource
}

private struct RepositoryDTO: Decodable {
    struct License: Decodable {
        let spdxID: String?

        private enum CodingKeys: String, CodingKey {
            case spdxID = "spdxId"
        }
    }
    let description: String?
    let isPrivate: Bool
    let isFork: Bool
    let isArchived: Bool
    let defaultBranch: String
    let stars: Int
    let forks: Int
    let openIssues: Int
    let language: String?
    let license: License?
    let topics: [String]
    let updatedAt: String?
    let htmlURL: String

    private enum CodingKeys: String, CodingKey {
        case description
        case isPrivate = "private"
        case isFork = "fork"
        case isArchived = "archived"
        case defaultBranch
        case stars = "stargazersCount"
        case forks = "forksCount"
        case openIssues = "openIssuesCount"
        case language, license, topics, updatedAt
        case htmlURL = "htmlUrl"
    }
}

private struct BranchDTO: Decodable {
    struct Commit: Decodable { let sha: String }
    let name: String
    let commit: Commit
}

private struct ReferenceNameDTO: Decodable {
    let name: String
}

private struct ContentLocation {
    let revision: String
    let path: String
}

private struct RepositoryReferenceKey: Hashable {
    let host: GitHubHost
    let repository: GitHubRepositoryPath
}

private struct CommitDTO: Decodable {
    struct Actor: Decodable { let login: String }
    struct Commit: Decodable {
        struct Author: Decodable {
            let name: String
            let date: String?
        }
        let message: String
        let author: Author?
    }
    let sha: String
    let commit: Commit
    let author: Actor?
    let htmlURL: String?

    private enum CodingKeys: String, CodingKey {
        case sha, commit, author
        case htmlURL = "htmlUrl"
    }
}

private struct ContentDTO: Decodable {
    let name: String
    let path: String
    let sha: String
    let size: Int
    let type: String
    let htmlURL: String?
    let downloadURL: String?
    let encoding: String?
    let content: String?

    private enum CodingKeys: String, CodingKey {
        case name, path, sha, size, type, encoding, content
        case htmlURL = "htmlUrl"
        case downloadURL = "downloadUrl"
    }
}

private struct DirectoryDTO: Decodable {
    let entries: [ContentDTO]
}
