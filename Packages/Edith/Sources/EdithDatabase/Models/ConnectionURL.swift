import Foundation

public enum DatabaseConnectionURLError: Error, Equatable, Sendable {
    case missingURL
    case invalidURL
    case unsupportedScheme(String)
    case missingHost
    case multipleHostsUnsupported
    case secureRedisUnsupported
}

extension DatabaseConnectionURLError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingURL:
            "Paste a database connection URL."
        case .invalidURL:
            "Enter a valid database connection URL."
        case .unsupportedScheme(let scheme):
            "The \(scheme) connection URL is not supported yet."
        case .missingHost:
            "The connection URL does not contain a database host."
        case .multipleHostsUnsupported:
            "Connections with multiple hosts are not supported yet."
        case .secureRedisUnsupported:
            "Secure Redis and Valkey URLs are not supported by the current adapter yet."
        }
    }
}

public struct ParsedDatabaseConnectionURL: Sendable {
    public let product: DatabaseProduct
    public let host: String
    public let port: Int
    public let path: String
    public let username: String
    public let password: String
    public let database: String
    public let authenticationDatabase: String
    public let tlsEnabled: Bool
    public let suggestedName: String
}

public enum DatabaseConnectionURLParser {
    public static func parse(
        _ input: String,
        preferredProduct: DatabaseProduct? = nil
    ) throws -> ParsedDatabaseConnectionURL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DatabaseConnectionURLError.missingURL }
        guard
            let components = URLComponents(string: value),
            let rawScheme = components.scheme?.lowercased(),
            !rawScheme.isEmpty
        else {
            throw DatabaseConnectionURLError.invalidURL
        }

        let product = try product(for: rawScheme, preferredProduct: preferredProduct)
        if product == .sqlite {
            return try sqliteResult(components: components)
        }
        if rawScheme == "rediss" || rawScheme == "valkeys" {
            throw DatabaseConnectionURLError.secureRedisUnsupported
        }
        guard let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
            !host.isEmpty
        else {
            throw DatabaseConnectionURLError.missingHost
        }
        guard !host.contains(",") else {
            throw DatabaseConnectionURLError.multipleHostsUnsupported
        }

        let database = databaseName(from: components.path, product: product)
        let authenticationDatabase =
            queryValue(named: "authSource", in: components) ?? "admin"
        let tlsEnabled = tlsEnabled(
            scheme: rawScheme,
            product: product,
            components: components)
        return ParsedDatabaseConnectionURL(
            product: product,
            host: host,
            port: components.port ?? DatabaseConnectionDraft.defaultPort(for: product),
            path: "",
            username: components.user ?? "",
            password: components.password ?? "",
            database: database,
            authenticationDatabase: authenticationDatabase,
            tlsEnabled: tlsEnabled,
            suggestedName: suggestedName(host: host, database: database, product: product))
    }

    private static func product(
        for scheme: String,
        preferredProduct: DatabaseProduct?
    ) throws -> DatabaseProduct {
        if scheme == "http" || scheme == "https" {
            guard preferredProduct == .elasticsearch || preferredProduct == .openSearch else {
                throw DatabaseConnectionURLError.unsupportedScheme(scheme)
            }
            return preferredProduct!
        }
        return switch scheme {
        case "postgres", "postgresql":
            .postgresql
        case "redis", "rediss":
            .redis
        case "valkey", "valkeys":
            .valkey
        case "mongodb":
            .mongoDB
        case "elasticsearch", "elasticsearchs":
            .elasticsearch
        case "opensearch", "opensearchs":
            .openSearch
        case "sqlite", "sqlite3", "file":
            .sqlite
        default:
            throw DatabaseConnectionURLError.unsupportedScheme(scheme)
        }
    }

    private static func sqliteResult(
        components: URLComponents
    ) throws -> ParsedDatabaseConnectionURL {
        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw DatabaseConnectionURLError.invalidURL }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return ParsedDatabaseConnectionURL(
            product: .sqlite,
            host: "",
            port: DatabaseConnectionDraft.defaultPort(for: .sqlite),
            path: path,
            username: "",
            password: "",
            database: "",
            authenticationDatabase: "admin",
            tlsEnabled: false,
            suggestedName: name.isEmpty ? "SQLite" : name)
    }

    private static func databaseName(
        from path: String,
        product: DatabaseProduct
    ) -> String {
        let value = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if product == .redis || product == .valkey {
            return value.isEmpty ? "0" : value
        }
        return value
    }

    private static func tlsEnabled(
        scheme: String,
        product: DatabaseProduct,
        components: URLComponents
    ) -> Bool {
        if product == .postgresql {
            let sslMode = queryValue(named: "sslmode", in: components)?.lowercased()
            return sslMode.map {
                ["require", "verify-ca", "verify-full"].contains($0)
            } ?? false
        }
        if product == .mongoDB {
            let value =
                queryValue(named: "tls", in: components)
                ?? queryValue(named: "ssl", in: components)
            return value?.lowercased() == "true" || value == "1"
        }
        if product == .elasticsearch || product == .openSearch {
            return scheme == "https" || scheme == "elasticsearchs" || scheme == "opensearchs"
        }
        return scheme == "rediss" || scheme == "valkeys"
    }

    private static func queryValue(
        named name: String,
        in components: URLComponents
    ) -> String? {
        components.queryItems?.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    private static func suggestedName(
        host: String,
        database: String,
        product: DatabaseProduct
    ) -> String {
        if !database.isEmpty, database != "0" {
            return database
        }
        return host.isEmpty ? product.displayName : host
    }
}
