import EdithDatabase
import Foundation

enum DatabaseConnectionFixtures {
    static let connectionID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "C1A90221-33A1-48CB-B0D7-00F8296E0091")!)

    static let environment = DatabaseEnvironmentMetadata(
        kind: .production,
        label: "Primary production",
        protection: .confirmationRequired)

    static let connectionIdentity = DatabaseConnectionIdentity(
        id: connectionID,
        displayName: "Orders",
        productHint: .postgresql,
        environment: environment)

    static func connectionDefinition() throws -> DatabaseConnectionDefinition {
        let passwordReference = DatabaseSecretReference(
            identifier: UUID(uuidString: "DEABF1B2-F9F1-47E0-98D7-B3B900375436")!,
            purpose: .password)
        let keyReference = DatabaseSecretReference(
            identifier: UUID(uuidString: "C4A00B07-3972-428E-8EAC-B3D51CA91B05")!,
            purpose: .clientPrivateKey)
        let certificateReference = DatabaseResourceReference(
            identifier: UUID(uuidString: "B9E7B038-E077-457A-8BF4-680230D7D37F")!,
            kind: .clientCertificate)
        let authorityReference = DatabaseResourceReference(
            identifier: UUID(uuidString: "E6E67468-3345-4493-92B0-728714F00984")!,
            kind: .certificateAuthority)
        let endpoint = DatabaseNetworkEndpoint(
            host: "database.internal",
            port: try DatabasePort(5_432),
            role: .primary)

        return DatabaseConnectionDefinition(
            id: connectionID,
            displayName: "Orders",
            productHint: .postgresql,
            location: .network([endpoint]),
            username: "edith",
            namespaces: DatabaseNamespaceDefaults(
                catalog: "orders",
                schema: "public",
                database: "orders"),
            deploymentMode: .primaryReplica,
            authentication: DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [passwordReference]),
            tls: DatabaseTLSConfiguration(
                mode: .required,
                verification: .full,
                serverName: "database.internal",
                certificateAuthority: authorityReference,
                clientCertificate: certificateReference,
                clientPrivateKey: keyReference),
            tunnel: DatabaseTunnelDefinition(
                machineIdentifier: "tuf-wired",
                remoteEndpoint: endpoint,
                requestedLocalPort: try DatabasePort(55_432)),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 10_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 60_000),
                poolSize: try DatabasePoolSize(8),
                idleTimeout: try DatabaseTimeout(milliseconds: 30_000),
                keepaliveInterval: try DatabaseTimeout(milliseconds: 15_000)),
            readOnlyPolicy: .preferred,
            productionPolicy: .requireMutationPreview,
            environment: environment,
            group: "Commerce",
            tags: ["orders", "critical"],
            color: "#C43D4B",
            isFavorite: true,
            options: [
                DatabaseNonSecretOption(name: "applicationName", value: .string("Edith"))
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastTestedAt: Date(timeIntervalSince1970: 1_700_000_200),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_300))
    }
}
