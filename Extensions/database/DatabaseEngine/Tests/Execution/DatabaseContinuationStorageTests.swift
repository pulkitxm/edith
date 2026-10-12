import Foundation
import GRDB
import Testing

@testable import DatabaseCore
@testable import DatabaseEngine

private actor LockedDatabaseSecretStore: DatabaseSecretStore {
    private(set) var accesses = 0
    private let missing: Bool

    init(missing: Bool = false) { self.missing = missing }

    private func fail(_ operation: DatabaseSecretStoreOperation) throws -> Never {
        accesses += 1
        throw DatabaseSecretStoreError.keychainFailure(operation: operation, status: -25308)
    }

    func store(_ secret: Data, for reference: DatabaseSecretReference) throws { try fail(.store) }
    func storeIfAbsent(_ secret: Data, for reference: DatabaseSecretReference) throws -> Data {
        try fail(.store)
    }
    func read(_ reference: DatabaseSecretReference) throws -> Data {
        if missing {
            accesses += 1
            throw DatabaseSecretStoreError.notFound(reference)
        }
        try fail(.read)
    }
    func delete(_ reference: DatabaseSecretReference) throws { try fail(.delete) }
    func contains(_ reference: DatabaseSecretReference) throws -> Bool { try fail(.contains) }
}

@Suite struct DatabaseContinuationStorageTests {
    @Test(arguments: [false, true], [false, true])
    func noAuthPagesWithoutTokensWorkWithLockedStorageButBrowsePaginationRequiresSigning(
        browse: Bool, paginated: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("synthetic.sqlite").path
        let database = try DatabaseQueue(path: path)
        try await database.write { database in
            try database.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)")
            try database.execute(sql: "INSERT INTO items VALUES (1, 'synthetic'), (2, 'synthetic')")
        }
        let secrets = LockedDatabaseSecretStore()
        let engine = DatabaseEngine(
            metadataFile: root.appendingPathComponent("metadata.sqlite"),
            secretStore: { secrets }, adapters: { [SQLiteDatabaseAdapter()] })
        let definition = try DatabaseConnectionDraft(
            displayName: "Synthetic SQLite", product: .sqlite, path: path,
            environmentKind: .testing, environmentLabel: "Synthetic",
            environmentProtection: .standard, readOnlyPolicy: .disabled,
            productionPolicy: .standard
        ).definition()
        _ = try await engine.send(.connectionSave(.init(connection: definition)))
        let page = DatabasePageRequest(pageSize: try DatabasePageSize(paginated ? 1 : 20))
        let response: DatabaseBrokerCommandResponse
        if browse {
            response = try await engine.send(
                .browse(
                    .init(
                        target: .init(
                            connectionID: definition.id,
                            object: .init(kind: .table, path: ["main", "items"])), page: page)))
        } else {
            response = try await engine.send(
                .query(
                    .init(
                        target: .init(connectionID: definition.id), language: .sql,
                        command: "SELECT * FROM items", page: page)))
        }
        let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        if paginated && browse {
            #expect(encoded.contains("Secure database credential storage is unavailable."))
            #expect(await secrets.accesses > 0)
        } else {
            #expect(encoded.contains("synthetic"))
            #expect(!encoded.contains("failed"))
            #expect(await secrets.accesses == 0)
            if paginated {
                #expect(encoded.contains("SQLite query continuation is unavailable."))
            }
        }
        await engine.shutdown()
    }

    @Test(arguments: [false, true])
    func requiredCredentialsStillFailBeforeConnectingWhenStorageIsUnavailable(missing: Bool)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = LockedDatabaseSecretStore(missing: missing)
        let engine = DatabaseEngine(
            metadataFile: root.appendingPathComponent("metadata.sqlite"),
            secretStore: { secrets }, adapters: { [SQLiteDatabaseAdapter()] })
        let original = try DatabaseConnectionDraft(
            displayName: "Synthetic SQLite", product: .sqlite,
            path: root.appendingPathComponent("synthetic.sqlite").path,
            environmentKind: .testing, environmentLabel: "Synthetic",
            environmentProtection: .standard, readOnlyPolicy: .disabled,
            productionPolicy: .standard
        ).definition()
        let definition = DatabaseConnectionDefinition(
            id: original.id, displayName: original.displayName, productHint: original.productHint,
            location: original.location,
            authentication: .init(
                kind: .password,
                secretReferences: [
                    .init(identifier: UUID(), purpose: .password)
                ]), tls: original.tls, limits: original.limits, environment: original.environment,
            createdAt: original.createdAt, updatedAt: original.updatedAt)
        _ = try await engine.send(.connectionSave(.init(connection: definition)))
        let response = try await engine.send(.connect(.init(connectionID: definition.id)))
        guard case .connect(let result) = response else {
            Issue.record("Connect returned an unexpected response")
            await engine.shutdown()
            return
        }
        #expect(result.payload == nil)
        #expect(result.error?.category == .authenticationFailed)
        #expect(await secrets.accesses > 0)
        await engine.shutdown()
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("synthetic.sqlite").path))
    }
}
