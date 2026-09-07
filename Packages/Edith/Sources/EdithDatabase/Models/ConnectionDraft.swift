import Foundation

public enum DatabaseConnectionDraftError: Error, Equatable, Sendable {
    case unsupportedProduct(DatabaseProduct)
    case missingName
    case missingHost
    case missingPath
    case missingUsername
    case unexpectedUsername
    case passwordRequired
    case passwordUnsupported
    case tlsUnsupported
    case invalidLogicalDatabase
}

extension DatabaseConnectionDraftError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedProduct(product):
            "\(product.displayName) is not supported by this version of Database."
        case .missingName:
            "Enter a connection name."
        case .missingHost:
            "Enter a database host."
        case .missingPath:
            "Choose a SQLite database file."
        case .missingUsername:
            "Enter a username for this database."
        case .unexpectedUsername:
            "Remove the username or add a password."
        case .passwordRequired:
            "Enter a password for this authentication method."
        case .passwordUnsupported:
            "SQLite connections do not use a stored password."
        case .tlsUnsupported:
            "TLS is not available for this database product yet."
        case .invalidLogicalDatabase:
            "The Redis database must be a whole number from 0 through 2147483647."
        }
    }
}

public struct DatabaseConnectionDraft: Hashable, Sendable {
    public static let supportedProducts: [DatabaseProduct] = [
        .postgresql, .mysql, .mariaDB, .sqlite, .redis, .valkey, .mongoDB, .elasticsearch,
        .openSearch, .clickHouse,
    ]

    public var id: DatabaseConnectionID
    public var displayName: String
    public var product: DatabaseProduct
    public var host: String
    public var port: Int
    public var path: String
    public var username: String
    public var database: String
    public var authenticationDatabase: String
    public var passwordReference: DatabaseSecretReference?
    public var tlsMode: DatabaseTLSMode
    public var environmentKind: DatabaseEnvironmentKind
    public var environmentLabel: String
    public var environmentProtection: DatabaseEnvironmentProtection
    public var readOnlyPolicy: DatabaseReadOnlyPolicy
    public var productionPolicy: DatabaseProductionPolicy

    public init(
        id: DatabaseConnectionID = DatabaseConnectionID(),
        displayName: String = "",
        product: DatabaseProduct = .postgresql,
        host: String = "127.0.0.1",
        port: Int? = nil,
        path: String = "",
        username: String = "",
        database: String = "",
        authenticationDatabase: String = "admin",
        passwordReference: DatabaseSecretReference? = nil,
        tlsMode: DatabaseTLSMode = .disabled,
        environmentKind: DatabaseEnvironmentKind = .development,
        environmentLabel: String = "Development",
        environmentProtection: DatabaseEnvironmentProtection = .confirmationRequired,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .required,
        productionPolicy: DatabaseProductionPolicy = .requireMutationPreview
    ) {
        self.id = id
        self.displayName = displayName
        self.product = product
        self.host = host
        self.port = port ?? Self.defaultPort(for: product)
        self.path = path
        self.username = username
        self.database = database
        self.authenticationDatabase = authenticationDatabase
        self.passwordReference = passwordReference
        self.tlsMode = tlsMode
        self.environmentKind = environmentKind
        self.environmentLabel = environmentLabel
        self.environmentProtection = environmentProtection
        self.readOnlyPolicy = readOnlyPolicy
        self.productionPolicy = productionPolicy
    }

    public static func defaultPort(for product: DatabaseProduct) -> Int {
        switch product {
        case .postgresql: 5_432
        case .mysql, .mariaDB: 3_306
        case .sqlite: 1
        case .redis, .valkey: 6_379
        case .mongoDB: 27_017
        case .elasticsearch, .openSearch: 9_200
        case .clickHouse: 8_123
        }
    }

    public func definition(createdAt: Date = Date()) throws -> DatabaseConnectionDefinition {
        guard Self.supportedProducts.contains(product) else {
            throw DatabaseConnectionDraftError.unsupportedProduct(product)
        }
        let name = displayName.trimmed
        guard !name.isEmpty else { throw DatabaseConnectionDraftError.missingName }
        let user = username.nilIfEmpty
        let namespace = database.nilIfEmpty
        let location = try makeLocation()
        let authentication = try makeAuthentication(username: user)
        let tls = try makeTLS()
        let label = environmentLabel.nilIfEmpty ?? environmentKind.rawValue.capitalized
        let limits = DatabaseConnectionLimits(
            connectionTimeout: try DatabaseTimeout(milliseconds: 10_000),
            operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
            poolSize: try DatabasePoolSize(1))
        return DatabaseConnectionDefinition(
            id: id,
            displayName: name,
            productHint: product,
            location: location,
            username: user,
            namespaces: try makeNamespaces(namespace),
            authentication: authentication,
            tls: tls,
            limits: limits,
            readOnlyPolicy: readOnlyPolicy,
            productionPolicy: productionPolicy,
            environment: DatabaseEnvironmentMetadata(
                kind: environmentKind,
                label: label,
                protection: environmentProtection),
            createdAt: createdAt,
            updatedAt: createdAt)
    }

    private func makeLocation() throws -> DatabaseConnectionLocation {
        if product == .sqlite {
            let filePath = path.trimmed
            guard !filePath.isEmpty else { throw DatabaseConnectionDraftError.missingPath }
            let access: DatabaseSQLiteAccessMode =
                readOnlyPolicy == .disabled ? .createIfMissing : .readOnly
            return .sqlite(DatabaseSQLiteLocation(path: filePath, accessMode: access))
        }
        let hostname = host.trimmed
        guard !hostname.isEmpty else { throw DatabaseConnectionDraftError.missingHost }
        return .network([
            DatabaseNetworkEndpoint(host: hostname, port: try DatabasePort(port))
        ])
    }

    private func makeAuthentication(username: String?) throws -> DatabaseAuthentication {
        if product == .sqlite {
            guard passwordReference == nil else {
                throw DatabaseConnectionDraftError.passwordUnsupported
            }
            guard username == nil else { throw DatabaseConnectionDraftError.unexpectedUsername }
            return DatabaseAuthentication(kind: .none)
        }
        switch product {
        case .postgresql, .mysql, .mariaDB:
            guard username != nil else { throw DatabaseConnectionDraftError.missingUsername }
            return passwordReference.map {
                DatabaseAuthentication(kind: .usernameAndPassword, secretReferences: [$0])
            } ?? DatabaseAuthentication(kind: .none)
        case .mongoDB:
            guard let passwordReference else {
                guard username == nil else {
                    throw DatabaseConnectionDraftError.passwordRequired
                }
                return DatabaseAuthentication(kind: .none)
            }
            guard username != nil else { throw DatabaseConnectionDraftError.missingUsername }
            return DatabaseAuthentication(
                kind: .scram,
                secretReferences: [passwordReference],
                source: authenticationDatabase.nilIfEmpty ?? "admin")
        case .redis, .valkey:
            guard let passwordReference else {
                guard username == nil else {
                    throw DatabaseConnectionDraftError.passwordRequired
                }
                return DatabaseAuthentication(kind: .none)
            }
            return DatabaseAuthentication(
                kind: username == nil ? .password : .usernameAndPassword,
                secretReferences: [passwordReference])
        case .elasticsearch, .openSearch, .clickHouse:
            guard let passwordReference else {
                guard product == .clickHouse || username == nil else {
                    throw DatabaseConnectionDraftError.passwordRequired
                }
                if product == .clickHouse, username == nil {
                    throw DatabaseConnectionDraftError.missingUsername
                }
                return DatabaseAuthentication(kind: .none)
            }
            guard username != nil else { throw DatabaseConnectionDraftError.missingUsername }
            return DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [passwordReference])
        case .sqlite:
            throw DatabaseConnectionDraftError.unsupportedProduct(product)
        }
    }

    private func makeTLS() throws -> DatabaseTLSConfiguration {
        if tlsMode == .disabled {
            return DatabaseTLSConfiguration(mode: .disabled, verification: .none)
        }
        guard
            product == .postgresql || product == .mysql || product == .mariaDB
                || product == .mongoDB
                || product == .elasticsearch
                || product == .openSearch || product == .clickHouse
        else {
            throw DatabaseConnectionDraftError.tlsUnsupported
        }
        return DatabaseTLSConfiguration(mode: .required, verification: .full)
    }

    private func makeNamespaces(_ value: String?) throws -> DatabaseNamespaceDefaults {
        switch product {
        case .redis, .valkey:
            let logicalDatabase = value ?? "0"
            guard let number = Int(logicalDatabase),
                (0...Int(Int32.max)).contains(number),
                number.description == logicalDatabase
            else {
                throw DatabaseConnectionDraftError.invalidLogicalDatabase
            }
            return DatabaseNamespaceDefaults(logicalDatabase: logicalDatabase)
        case .postgresql, .mysql, .mariaDB, .mongoDB, .clickHouse:
            return DatabaseNamespaceDefaults(database: value)
        case .sqlite, .elasticsearch, .openSearch:
            return DatabaseNamespaceDefaults()
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
