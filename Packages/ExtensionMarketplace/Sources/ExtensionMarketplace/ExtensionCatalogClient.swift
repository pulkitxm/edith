import Foundation

public actor ExtensionCatalogClient {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public struct Result: Sendable {
        public let catalog: ExtensionCatalog
        public let offline: Bool
    }

    private enum Source: Sendable {
        case envelope(URL)
        case release(repository: String, tag: String)
    }

    private struct TransportFailure: Error { let underlying: Error }

    private let source: Source
    private let publicKey: Data
    private let repository: String
    private let cache: URL
    private let fetch: Fetch

    public init(url: URL, publicKey: Data, repository: String, cache: URL, fetch: @escaping Fetch) {
        self.source = .envelope(url)
        self.publicKey = publicKey
        self.repository = repository
        self.cache = cache
        self.fetch = fetch
    }

    public init(
        releaseRepository: String, catalogTag: String, publicKey: Data, cache: URL,
        fetch: @escaping Fetch
    ) {
        self.source = .release(repository: releaseRepository, tag: catalogTag)
        self.publicKey = publicKey
        self.repository = releaseRepository
        self.cache = cache
        self.fetch = fetch
    }

    public static func live(cache: URL) -> ExtensionCatalogClient {
        ExtensionCatalogClient(
            releaseRepository: MarketplaceConfiguration.repository,
            catalogTag: MarketplaceConfiguration.catalogTag,
            publicKey: MarketplaceConfiguration.publicKey, cache: cache
        ) { url in
            var request = URLRequest(
                url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Edith", forHTTPHeaderField: "User-Agent")
            request.setValue(
                url.host == "api.github.com"
                    ? "application/vnd.github+json" : "application/octet-stream",
                forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                data.count <= 3 * 1024 * 1024
            else { throw MarketplaceError.downloadFailed }
            return data
        }
    }

    public func cached() throws -> ExtensionCatalog? {
        guard FileManager.default.fileExists(atPath: cache.path) else { return nil }
        return try decode(Data(contentsOf: cache), minimumRevision: 0)
    }

    public func refresh() async throws -> Result {
        let previous = try? cached()
        let data: Data
        let pointer: ExtensionCatalogPointer?
        do {
            (data, pointer) = try await load()
        } catch let failure as TransportFailure {
            try Task.checkCancellation()
            if let previous { return Result(catalog: previous, offline: true) }
            throw failure.underlying
        }
        try Task.checkCancellation()
        let operation = try PackageFileLock(
            url: cache.appendingPathExtension("lock"), exclusive: true)
        defer { operation.close() }
        let latest = try? cached()
        let latestKnownRevision = max(previous?.revision ?? 0, latest?.revision ?? 0)
        let catalog = try decode(data, minimumRevision: latestKnownRevision)
        if let pointer, pointer.revision != catalog.revision {
            throw MarketplaceError.invalidCatalog
        }
        for known in [previous, latest].compactMap({ $0 })
        where known.revision == catalog.revision {
            guard known == catalog else { throw MarketplaceError.invalidCatalog }
        }
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cache, options: .atomic)
        return Result(catalog: catalog, offline: false)
    }

    private func download(_ url: URL) async throws -> Data {
        do { return try await fetch(url) } catch { throw TransportFailure(underlying: error) }
    }

    private func load() async throws -> (Data, ExtensionCatalogPointer?) {
        switch source {
        case .envelope(let url): return (try await download(url), nil)
        case .release(let repository, let tag):
            guard repository.split(separator: "/", omittingEmptySubsequences: false).count == 2,
                repository.split(separator: "/").allSatisfy({
                    ExtensionPackage.validComponent(String($0))
                }),
                ExtensionPackage.validComponent(tag),
                let url = URL(
                    string: "https://api.github.com/repos/\(repository)/releases/tags/\(tag)")
            else { throw MarketplaceError.invalidCatalog }
            let metadata = try await download(url)
            guard metadata.count <= 3 * 1024 * 1024 else { throw MarketplaceError.invalidCatalog }
            let release = try JSONDecoder().decode(CatalogRelease.self, from: metadata)
            guard !release.draft, release.tag_name == tag else {
                throw MarketplaceError.invalidCatalog
            }
            let pointer = try ExtensionCatalogPointer.parse(release.body)
            let matches = release.assets.filter { $0.name == pointer.assetName }
            guard matches.count == 1, matches[0].size == pointer.bytes,
                let assetURL = URL(
                    string:
                        "https://github.com/\(repository)/releases/download/\(tag)/\(pointer.assetName)"
                )
            else { throw MarketplaceError.invalidCatalog }
            try Task.checkCancellation()
            let data = try await download(assetURL)
            try pointer.verify(data)
            return (data, pointer)
        }
    }

    private struct CatalogRelease: Decodable {
        let body: String
        let tag_name: String
        let draft: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let size: Int
        }
    }

    private func decode(_ data: Data, minimumRevision: Int64) throws -> ExtensionCatalog {
        guard data.count <= 3 * 1024 * 1024 else { throw MarketplaceError.invalidCatalog }
        return try JSONDecoder().decode(SignedExtensionCatalog.self, from: data).verified(
            publicKey: publicKey, repository: repository, minimumRevision: minimumRevision)
    }
}
