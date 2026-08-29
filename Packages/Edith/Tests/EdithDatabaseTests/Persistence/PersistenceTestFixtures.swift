import EdithDatabase
import Foundation

enum DatabasePersistenceFixtures {
    static func temporaryStorePath() throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-database-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("metadata.sqlite").path)
    }

    static func connection(
        id: UUID,
        name: String,
        product: DatabaseProduct = .postgresql,
        environment: DatabaseEnvironmentKind = .development,
        group: String? = nil,
        tags: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        lastUsedAt: Date? = nil
    ) throws -> DatabaseConnectionDefinition {
        let connectionID = DatabaseConnectionID(rawValue: id)
        return DatabaseConnectionDefinition(
            id: connectionID,
            displayName: name,
            productHint: product,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(5_432))
            ]),
            username: "edith",
            namespaces: DatabaseNamespaceDefaults(database: "edith_lab"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(kind: .none),
            tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            readOnlyPolicy: .disabled,
            productionPolicy: .standard,
            environment: DatabaseEnvironmentMetadata(
                kind: environment,
                label: environment.rawValue,
                protection: environment == .production ? .confirmationRequired : .standard),
            group: group,
            tags: tags,
            isFavorite: isFavorite,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt)
    }

    static func savedQuery(
        id: UUID,
        connectionID: DatabaseConnectionID? = nil,
        name: String,
        language: DatabaseSavedQueryLanguage,
        text: String,
        tags: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) -> DatabaseSavedQuery {
        DatabaseSavedQuery(
            id: DatabaseSavedQueryID(rawValue: id),
            connectionID: connectionID,
            name: name,
            language: language,
            text: text,
            tags: tags,
            isFavorite: isFavorite,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    static func operation(
        id: UUID,
        connection: DatabaseConnectionDefinition,
        kind: DatabaseOperationKind,
        state: DatabaseOperationState,
        startedAt: Date,
        finishedAt: Date?
    ) -> DatabaseOperationRecordSummary {
        DatabaseOperationRecordSummary(
            id: DatabaseOperationID(rawValue: id),
            kind: kind,
            state: state,
            connection: connection.identity,
            startedAt: startedAt,
            finishedAt: finishedAt,
            cancellationSupport: .serverSide,
            retryClassification: .safeIdempotent,
            pageCount: 2,
            recordCount: 400,
            byteCount: 8_192)
    }
}
