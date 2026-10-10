import Foundation

public actor ExtensionCatalogClient {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public struct Result: Sendable {
        public let catalog: ExtensionCatalog
        public let offline: Bool
    }

    private let url: URL
    private let publicKey: Data
    private let repository: String
    private let cache: URL
    private let fetch: Fetch

    public init(url: URL, publicKey: Data, repository: String, cache: URL, fetch: @escaping Fetch) {
        self.url = url
        self.publicKey = publicKey
        self.repository = repository
        self.cache = cache
        self.fetch = fetch
    }

    public static func live(cache: URL, url: URL = MarketplaceConfiguration.catalogURL)
        -> ExtensionCatalogClient
    {
        ExtensionCatalogClient(
            url: url, publicKey: MarketplaceConfiguration.publicKey,
            repository: MarketplaceConfiguration.repository, cache: cache
        ) { url in
            var request = URLRequest(
                url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Edith", forHTTPHeaderField: "User-Agent")
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
        do {
            data = try await fetch(url)
        } catch {
            try Task.checkCancellation()
            if let previous { return Result(catalog: previous, offline: true) }
            throw error
        }
        try Task.checkCancellation()
        let operation = try PackageFileLock(
            url: cache.appendingPathExtension("lock"), exclusive: true)
        defer { operation.close() }
        let latest = try? cached()
        let latestKnownRevision = max(previous?.revision ?? 0, latest?.revision ?? 0)
        let catalog = try decode(data, minimumRevision: latestKnownRevision)
        for known in [previous, latest].compactMap({ $0 })
        where known.revision == catalog.revision {
            guard known == catalog else { throw MarketplaceError.invalidCatalog }
        }
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cache, options: .atomic)
        return Result(catalog: catalog, offline: false)
    }

    private func decode(_ data: Data, minimumRevision: Int64) throws -> ExtensionCatalog {
        guard data.count <= 3 * 1024 * 1024 else { throw MarketplaceError.invalidCatalog }
        return try JSONDecoder().decode(SignedExtensionCatalog.self, from: data).verified(
            publicKey: publicKey, repository: repository, minimumRevision: minimumRevision)
    }
}
