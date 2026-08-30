import EdithDatabase
import Foundation

actor DatabaseMCPScriptedSender: DatabaseBrokerCommandSending {
    private var results: [Result<DatabaseBrokerCommandResponse, DatabaseBrokerCommandClientError>]
    private var requests: [DatabaseBrokerCommandRequest] = []

    init(
        _ results: [Result<DatabaseBrokerCommandResponse, DatabaseBrokerCommandClientError>]
    ) {
        self.results = results
    }

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        requests.append(request)
        guard !results.isEmpty else {
            throw DatabaseBrokerCommandClientError.unavailable
        }
        return try results.removeFirst().get()
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] {
        requests
    }
}

enum DatabaseMCPFixtures {
    static let connectionID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "5D3D5C88-49D9-4DC4-9B74-3926B7AA9F9E")!)
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "C95C9914-17B0-44D3-A09E-498E0EFC6352")!)
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static let completeMetadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))

    static func connection() throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: connectionID,
            displayName: "Primary orders",
            productHint: .postgresql,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "sensitive.internal.example",
                    port: try DatabasePort(5_432))
            ]),
            username: "secret-user",
            namespaces: DatabaseNamespaceDefaults(
                catalog: "orders-catalog",
                schema: "public",
                database: "orders"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(kind: .password),
            tls: DatabaseTLSConfiguration(mode: .required, verification: .full),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            readOnlyPolicy: .preferred,
            productionPolicy: .requireMutationPreview,
            environment: DatabaseEnvironmentMetadata(
                kind: .production,
                label: "customer-a",
                protection: .confirmationRequired),
            group: "Payments",
            tags: ["favorite", "critical"],
            color: "orange",
            isFavorite: true,
            createdAt: now,
            updatedAt: now,
            lastTestedAt: now,
            lastUsedAt: now)
    }

    static func capabilityReport() -> DatabaseCapabilityReport {
        DatabaseCapabilityReport(
            productIdentity: DatabaseProductIdentity(
                product: .postgresql,
                version: DatabaseVersion(string: "17.11", major: 17, minor: 11),
                distribution: "PostgreSQL",
                topology: DatabaseTopology(
                    kind: .primaryReplica,
                    nodeCount: 2,
                    replicaCount: 1),
                modules: [DatabaseExtensionIdentity(name: "pg_stat_statements")]),
            capabilities: [
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available,
                    limits: [
                        DatabaseCapabilityLimit(name: "page", value: 500, unit: "records")
                    ]),
                DatabaseCapabilityStatus(
                    id: .schemaMutation,
                    requirement: .productRequired,
                    availability: .unavailable,
                    reason: DatabaseCapabilityUnavailableReason(
                        category: .permission,
                        message: "Schema mutation is unavailable.",
                        missingPermissions: ["CREATE"])),
            ],
            permissions: [
                DatabasePermissionStatus(name: "SELECT", granted: true, scope: "orders")
            ],
            pagingModes: [.keyset, .serverCursor],
            mutationModes: [.transactionalBatch],
            transactionModes: [.explicit, .savepoints],
            cancellationModes: [.protocolCancellation],
            exportFormats: [.csv, .jsonLines],
            explainModes: [.logical, .analyzed],
            safetyLimitations: ["DDL requires elevated privileges."],
            discoveredAt: now,
            expiresAt: now.addingTimeInterval(300))
    }
}
