import ExtensionMarketplace
import Foundation

public struct HostDevelopmentCatalog: Equatable, Sendable {
    public static let locationKey = "EDITH_DEV_CATALOG"
    public static let publicKeyKey = "EDITH_DEV_CATALOG_KEY"

    public let base: URL
    public let publicKey: Data

    public init?(environment: [String: String], development: Bool) {
        guard development, let raw = environment[Self.locationKey],
            let base = URL(string: raw), base.scheme == "http",
            ["127.0.0.1", "localhost"].contains(base.host ?? ""),
            base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
            let encoded = environment[Self.publicKeyKey],
            let publicKey = Data(base64Encoded: encoded), publicKey.count == 32
        else { return nil }
        self.base = base
        self.publicKey = publicKey
    }

    public var catalogURL: URL { base.appendingPathComponent("catalog.json") }

    public func localURL(for download: URL, repository: String) -> URL? {
        let prefix = "/\(repository)/releases/download/"
        guard download.scheme == "https", download.host == "github.com",
            download.path.hasPrefix(prefix)
        else { return nil }
        let components = download.path.dropFirst(prefix.count).split(separator: "/")
        guard components.count == 2,
            components.allSatisfy({ ExtensionPackage.validComponent(String($0)) })
        else { return nil }
        return base.appendingPathComponent("releases").appendingPathComponent(
            String(components[0])
        ).appendingPathComponent(String(components[1]))
    }

    public func client(cache: URL) -> ExtensionCatalogClient {
        ExtensionCatalogClient(
            url: catalogURL, publicKey: publicKey,
            repository: MarketplaceConfiguration.repository, cache: cache
        ) { url in
            let request = URLRequest(
                url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                data.count <= 3 * 1024 * 1024
            else { throw MarketplaceError.downloadFailed }
            return data
        }
    }
}
