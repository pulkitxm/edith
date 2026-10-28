import Foundation

public actor ExtensionCatalogClient {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public enum Fallback: Sendable, Equatable {
        case offline
        case rateLimited
        case unavailable

        public var message: String? {
            switch self {
            case .offline: nil
            case .rateLimited:
                "GitHub is limiting requests from this network. Showing the last known catalog."
            case .unavailable:
                "The extension catalog could not be refreshed. Showing the last known catalog."
            }
        }

        init(_ error: Error) {
            if let marketplace = error as? MarketplaceError, marketplace == .rateLimited {
                self = .rateLimited
            } else if let url = error as? URLError, Self.offlineCodes.contains(url.code) {
                self = .offline
            } else {
                self = .unavailable
            }
        }

        private static let offlineCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .timedOut,
            .internationalRoamingOff,
        ]
    }

    public struct Result: Sendable {
        public let catalog: ExtensionCatalog
        public let fallback: Fallback?
        public var offline: Bool { fallback == .offline }
    }

    private struct TransportFailure: Error { let underlying: Error }

    private let source: URL?
    private let release: (repository: String, tag: String)?
    private let retryDelays: [Duration]
    private let publicKey: Data
    private let repository: String
    private let cache: URL
    private let fetch: Fetch

    public init(
        url: URL, publicKey: Data, repository: String, cache: URL,
        retryDelays: [Duration] = [], fetch: @escaping Fetch
    ) {
        self.source = url
        self.release = nil
        self.retryDelays = retryDelays
        self.publicKey = publicKey
        self.repository = repository
        self.cache = cache
        self.fetch = fetch
    }

    public init(
        releaseRepository: String, catalogTag: String, publicKey: Data, cache: URL,
        retryDelays: [Duration] = [], fetch: @escaping Fetch
    ) {
        self.source = nil
        self.release = (releaseRepository, catalogTag)
        self.retryDelays = retryDelays
        self.publicKey = publicKey
        self.repository = releaseRepository
        self.cache = cache
        self.fetch = fetch
    }

    public static func live(cache: URL) -> ExtensionCatalogClient {
        ExtensionCatalogClient(
            releaseRepository: MarketplaceConfiguration.repository,
            catalogTag: MarketplaceConfiguration.catalogTag,
            publicKey: MarketplaceConfiguration.publicKey, cache: cache,
            retryDelays: [.seconds(1), .seconds(4)]
        ) { url in
            var request = URLRequest(
                url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Edith", forHTTPHeaderField: "User-Agent")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw MarketplaceError.downloadFailed
            }
            if response.statusCode == 403 || response.statusCode == 429 {
                throw MarketplaceError.rateLimited
            }
            guard response.statusCode == 200, data.count <= 3 * 1024 * 1024 else {
                throw MarketplaceError.downloadFailed
            }
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
            data = try await load()
        } catch let failure as TransportFailure {
            try Task.checkCancellation()
            if let previous {
                return Result(catalog: previous, fallback: Fallback(failure.underlying))
            }
            throw failure.underlying
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
        return Result(catalog: catalog, fallback: nil)
    }

    private func download(_ url: URL) async throws -> Data {
        var delays = retryDelays[...]
        while true {
            do { return try await fetch(url) } catch {
                try Task.checkCancellation()
                guard let delay = delays.popFirst(),
                    Self.transient(error)
                else { throw TransportFailure(underlying: error) }
                try await Task.sleep(for: delay)
            }
        }
    }

    private static func transient(_ error: Error) -> Bool {
        error is URLError || (error as? MarketplaceError) == .downloadFailed
            || (error as? MarketplaceError) == .rateLimited
    }

    private func load() async throws -> Data {
        if let source { return try await download(source) }
        guard let release, release.repository.split(separator: "/", omittingEmptySubsequences: false).count == 2,
            release.repository.split(separator: "/").allSatisfy({
                ExtensionPackage.validComponent(String($0))
            }),
            ExtensionPackage.validComponent(release.tag),
            let url = URL(
                string:
                    "https://github.com/\(release.repository)/releases/download/\(release.tag)/catalog.json"
            )
        else { throw MarketplaceError.invalidCatalog }
        return try await download(url)
    }

    private func decode(_ data: Data, minimumRevision: Int64) throws -> ExtensionCatalog {
        guard data.count <= 3 * 1024 * 1024 else { throw MarketplaceError.invalidCatalog }
        return try JSONDecoder().decode(SignedExtensionCatalog.self, from: data).verified(
            publicKey: publicKey, repository: repository, minimumRevision: minimumRevision)
    }
}
