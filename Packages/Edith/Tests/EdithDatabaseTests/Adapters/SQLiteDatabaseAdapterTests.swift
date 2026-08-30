import Foundation
import Testing

@testable import EdithDatabase

private enum SQLiteDatabaseAdapterFixtures {
    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-sqlite-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    static func definition(
        product: DatabaseProduct = .sqlite,
        location: DatabaseConnectionLocation = .memory(name: nil),
        version: Int = DatabaseConnectionDefinition.schemaVersion,
        username: String? = nil,
        deploymentMode: DatabaseDeploymentMode = .automatic,
        authentication: DatabaseAuthentication = DatabaseAuthentication(kind: .none),
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none),
        tunnel: DatabaseTunnelDefinition? = nil,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .disabled,
        environmentProtection: DatabaseEnvironmentProtection = .standard,
        options: [DatabaseNonSecretOption] = []
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            version: version,
            id: DatabaseConnectionID(),
            displayName: "SQLite fixture",
            productHint: product,
            location: location,
            username: username,
            namespaces: DatabaseNamespaceDefaults(),
            deploymentMode: deploymentMode,
            authentication: authentication,
            tls: tls,
            tunnel: tunnel,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 2_000),
                poolSize: try DatabasePoolSize(1)),
            readOnlyPolicy: readOnlyPolicy,
            productionPolicy: .standard,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "Testing",
                protection: environmentProtection),
            options: options,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func resolved(
        _ definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data] = [:]
    ) throws(DatabaseAdapterFailure) -> DatabaseResolvedConnection {
        try DatabaseResolvedConnection(
            definition: definition,
            secrets: secrets)
    }

    static func context(
        deadline: Date? = nil,
        cancellation: DatabaseAdapterCancellationSignal = DatabaseAdapterCancellationSignal()
    ) -> DatabaseAdapterOperationContext {
        DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(deadline: deadline),
            cancellation: cancellation)
    }

    static func connect(
        _ definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data] = [:],
        context: DatabaseAdapterOperationContext? = nil
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await SQLiteDatabaseAdapter().connect(
            try resolved(definition, secrets: secrets),
            context: context ?? self.context())
    }

    static func createFile(
        at path: String,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .disabled
    ) async throws {
        let definition = try definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .createIfMissing)),
            readOnlyPolicy: readOnlyPolicy)
        let session = try await connect(definition)
        await session.disconnect()
    }

    static func target(
        connectionID: DatabaseConnectionID
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .table, path: ["main", "items"]))
    }

    static func pageRequest(
        connectionID: DatabaseConnectionID
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: target(connectionID: connectionID),
            page: DatabasePageRequest(pageSize: try DatabasePageSize(10)),
            continuation: nil)
    }

    static func queryRequest(
        connectionID: DatabaseConnectionID
    ) throws -> DatabaseAdapterQueryRequest {
        try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: target(connectionID: connectionID),
                language: .sql,
                command: "SELECT 1",
                page: DatabasePageRequest(pageSize: try DatabasePageSize(10))),
            continuation: nil)
    }

    static func destructiveRequest(
        connectionID: DatabaseConnectionID
    ) -> DatabaseDestructiveRequest {
        DatabaseDestructiveRequest(
            target: target(connectionID: connectionID),
            payload: .relational(
                product: .sqlite,
                statement: "DELETE FROM items",
                parameters: []))
    }

    static func destructivePlan(
        connectionID: DatabaseConnectionID
    ) -> DatabaseDestructivePlan {
        DatabaseDestructivePlan(
            request: destructiveRequest(connectionID: connectionID),
            action: .deleteMany,
            scope: .entireObject,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 0, accuracy: .unknown),
                description: "Unknown impact"),
            transactionBehavior: .transactional,
            rollbackAvailability: .available,
            executionMode: .synchronous)
    }

    static func failure<Value>(
        _ operation: () async throws -> Value
    ) async -> DatabaseAdapterFailure? {
        do {
            _ = try await operation()
            return nil
        } catch let failure as DatabaseAdapterFailure {
            return failure
        } catch {
            Issue.record("Expected an adapter failure, received \(type(of: error))")
            return nil
        }
    }

    static func expectReported(
        _ failure: DatabaseAdapterFailure?,
        category: DatabaseErrorCategory,
        productCode: String
    ) {
        guard case let .reported(envelope) = failure else {
            Issue.record("Expected a reported adapter failure")
            return
        }
        #expect(envelope.category == category)
        #expect(envelope.productCode == productCode)
        #expect(envelope.target == nil)
        #expect(envelope.details.isEmpty)
    }
}

@Suite struct SQLiteDatabaseAdapterTests {
    @Test func connectsToIndependentAndNamedMemoryDatabases() async throws {
        let adapter = SQLiteDatabaseAdapter()
        #expect(adapter.id.rawValue == "sqlite")
        #expect(adapter.products == [.sqlite])

        let independentDefinition = try SQLiteDatabaseAdapterFixtures.definition()
        let independent = try await SQLiteDatabaseAdapterFixtures.connect(independentDefinition)
        #expect(await independent.lifecycleState() == .connected)
        #expect(independent.productIdentity.product == .sqlite)
        #expect(independent.productIdentity.distribution == "SQLite")
        #expect(independent.productIdentity.topology.kind == .embedded)
        #expect(independent.productIdentity.topology.nodeCount == 1)
        #expect(independent.productIdentity.version?.major != nil)
        #expect(independent.productIdentity.version?.minor != nil)
        #expect(independent.productIdentity.version?.patch != nil)

        let name = "memory_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let namedDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .memory(name: name))
        let named = try await SQLiteDatabaseAdapterFixtures.connect(namedDefinition)
        #expect(await named.lifecycleState() == .connected)
        #expect(named.productIdentity == independent.productIdentity)

        let protectedDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .memory(name: nil),
            readOnlyPolicy: .required)
        let protectedValue = try await SQLiteDatabaseAdapterFixtures.connect(protectedDefinition)
        let protected = try #require(protectedValue as? SQLiteDatabaseAdapterSession)
        #expect(await protected.readOnlyEnforcementIsActive())
        _ = try await protected.discoverCapabilities(
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(await protected.readOnlyEnforcementIsActive())

        await independent.disconnect()
        await named.disconnect()
        await protected.disconnect()
    }

    @Test func honorsFileAccessModesAndReadOnlyPolicies() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("database file.sqlite").path

        let createDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .createIfMissing)))
        let created = try await SQLiteDatabaseAdapterFixtures.connect(createDefinition)
        let createdSession = try #require(created as? SQLiteDatabaseAdapterSession)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(await createdSession.resourceIsOpen())
        #expect(!(await createdSession.readOnlyEnforcementIsActive()))
        await created.disconnect()

        let readWriteDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .readWrite)))
        let readWrite = try await SQLiteDatabaseAdapterFixtures.connect(readWriteDefinition)
        let readWriteSession = try #require(readWrite as? SQLiteDatabaseAdapterSession)
        #expect(!(await readWriteSession.readOnlyEnforcementIsActive()))
        await readWrite.disconnect()

        let readOnlyDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .readOnly)))
        let readOnly = try await SQLiteDatabaseAdapterFixtures.connect(readOnlyDefinition)
        let readOnlySession = try #require(readOnly as? SQLiteDatabaseAdapterSession)
        #expect(await readOnlySession.readOnlyEnforcementIsActive())
        await readOnly.disconnect()

        let policyDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .readWrite)),
            readOnlyPolicy: .preferred)
        let policySessionValue = try await SQLiteDatabaseAdapterFixtures.connect(policyDefinition)
        let policySession = try #require(
            policySessionValue as? SQLiteDatabaseAdapterSession)
        #expect(await policySession.readOnlyEnforcementIsActive())
        await policySession.disconnect()

        let protectedPath = directory.appendingPathComponent("protected.sqlite").path
        let protectedDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: protectedPath,
                    accessMode: .createIfMissing)),
            environmentProtection: .readOnly)
        let protectedValue = try await SQLiteDatabaseAdapterFixtures.connect(protectedDefinition)
        let protectedSession = try #require(
            protectedValue as? SQLiteDatabaseAdapterSession)
        #expect(await protectedSession.readOnlyEnforcementIsActive())
        await protectedSession.disconnect()
    }

    @Test func readWriteAndReadOnlyNeverCreateMissingFiles() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for mode in [DatabaseSQLiteAccessMode.readWrite, .readOnly] {
            let path = directory.appendingPathComponent("missing-\(mode.rawValue).sqlite").path
            let definition = try SQLiteDatabaseAdapterFixtures.definition(
                location: .sqlite(
                    DatabaseSQLiteLocation(path: path, accessMode: mode)))
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await SQLiteDatabaseAdapterFixtures.connect(definition)
            }

            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .connectionFailed,
                productCode: "sqlite.open_failed")
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test func rejectsUnsafeFileLocationsAndBookmarks() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.sqlite")
        try await SQLiteDatabaseAdapterFixtures.createFile(at: target.path)
        let symbolicLink = directory.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: target)

        let bookmark = DatabaseResourceReference(
            identifier: UUID(),
            kind: .sqliteBookmark)
        let invalidLocations: [DatabaseConnectionLocation] = [
            .sqlite(DatabaseSQLiteLocation(path: "relative.sqlite")),
            .sqlite(DatabaseSQLiteLocation(path: directory.path)),
            .sqlite(
                DatabaseSQLiteLocation(
                    path: directory.appendingPathComponent("missing/child.sqlite").path,
                    accessMode: .createIfMissing)),
            .sqlite(DatabaseSQLiteLocation(path: symbolicLink.path)),
        ]

        for location in invalidLocations {
            let definition = try SQLiteDatabaseAdapterFixtures.definition(location: location)
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await SQLiteDatabaseAdapterFixtures.connect(definition)
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .invalidRequest,
                productCode: "sqlite.connection.invalid")
        }

        let bookmarkedDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: target.path,
                    fileReference: bookmark)))
        let bookmarkFailure = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(bookmarkedDefinition)
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            bookmarkFailure,
            category: .unsupported,
            productCode: "sqlite.file_bookmark.unavailable")
    }

    @Test func rejectsNonSQLiteAndUnsupportedSecurityConfiguration() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("database.sqlite").path
        try await SQLiteDatabaseAdapterFixtures.createFile(at: path)
        let location = DatabaseConnectionLocation.sqlite(
            DatabaseSQLiteLocation(path: path))
        let secretReference = DatabaseSecretReference(
            identifier: UUID(),
            purpose: .password)
        let endpoint = DatabaseNetworkEndpoint(
            host: "127.0.0.1",
            port: try DatabasePort(5_432))

        let invalidDefinitions = try [
            SQLiteDatabaseAdapterFixtures.definition(
                product: .postgresql,
                location: location),
            SQLiteDatabaseAdapterFixtures.definition(
                location: .network([endpoint])),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                version: DatabaseConnectionDefinition.schemaVersion + 1),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                username: "local-user"),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                deploymentMode: .standalone),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                authentication: DatabaseAuthentication(
                    kind: .password,
                    secretReferences: [secretReference])),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                tls: DatabaseTLSConfiguration(
                    mode: .required,
                    verification: .full,
                    serverName: "localhost")),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                tunnel: DatabaseTunnelDefinition(
                    machineIdentifier: "machine",
                    remoteEndpoint: endpoint)),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                options: [
                    DatabaseNonSecretOption(
                        name: "unknown",
                        value: .boolean(true))
                ]),
        ]

        for definition in invalidDefinitions {
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await SQLiteDatabaseAdapterFixtures.connect(definition)
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .invalidRequest,
                productCode: "sqlite.connection.invalid")
        }

        let secretDefinition = try SQLiteDatabaseAdapterFixtures.definition(location: location)
        let secretFailure = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(
                secretDefinition,
                secrets: [secretReference: Data("private-value".utf8)])
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            secretFailure,
            category: .invalidRequest,
            productCode: "sqlite.connection.invalid")
    }

    @Test func rejectsUnsafeNamedMemoryIdentifiers() async throws {
        for name in ["", "name?mode=memory", "name/child", String(repeating: "a", count: 129)] {
            let definition = try SQLiteDatabaseAdapterFixtures.definition(
                location: .memory(name: name))
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await SQLiteDatabaseAdapterFixtures.connect(definition)
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .invalidRequest,
                productCode: "sqlite.connection.invalid")
        }
    }

    @Test func reportsOnlyImplementedCapabilities() async throws {
        let definition = try SQLiteDatabaseAdapterFixtures.definition()
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let report = try await session.discoverCapabilities(
            context: SQLiteDatabaseAdapterFixtures.context())
        let expectedUnavailable: Set<DatabaseCapabilityID> = [
            .objectDiscovery,
            .objectDescription,
            .query,
            .queryCancellation,
            .explain,
            .browse,
            .insert,
            .update,
            .delete,
            .bulkMutation,
            .importData,
            .exportData,
            .transactions,
            .schemaMutation,
            .monitoring,
            .administration,
        ]

        #expect(report.productIdentity == session.productIdentity)
        #expect(report.status(for: .connectionTest)?.availability == .available)
        #expect(report.capabilities.count == expectedUnavailable.count + 1)
        for identifier in expectedUnavailable {
            let status = report.status(for: identifier)
            #expect(status?.availability == .unavailable)
            #expect(status?.reason?.category == .notImplemented)
            #expect(status?.isAvailable == false)
        }
        #expect(report.pagingModes.isEmpty)
        #expect(report.mutationModes == [.unsupported])
        #expect(report.transactionModes == [.none])
        #expect(report.cancellationModes == [.cooperative])
        #expect(report.importFormats.isEmpty)
        #expect(report.exportFormats.isEmpty)
        #expect(report.explainModes.isEmpty)

        await session.disconnect()
    }

    @Test func unsupportedOperationsUseOneStableRedactedFailure() async throws {
        let definition = try SQLiteDatabaseAdapterFixtures.definition()
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let page = try SQLiteDatabaseAdapterFixtures.pageRequest(
            connectionID: definition.id)
        let query = try SQLiteDatabaseAdapterFixtures.queryRequest(
            connectionID: definition.id)
        let destructiveRequest = SQLiteDatabaseAdapterFixtures.destructiveRequest(
            connectionID: definition.id)
        let destructivePlan = SQLiteDatabaseAdapterFixtures.destructivePlan(
            connectionID: definition.id)
        let stream = DatabaseAdapterStreamRequest(source: .browse(page))
        let context = SQLiteDatabaseAdapterFixtures.context()

        let failures = [
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.readPage(page, context: context)
            },
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.query(query, context: context)
            },
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.normalizeMutation(destructiveRequest, context: context)
            },
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.executeMutation(destructivePlan, context: context)
            },
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.openStream(stream, context: context)
            },
        ]
        let expected = DatabaseAdapterFailure.reported(
            DatabaseErrorEnvelope(
                category: .unsupported,
                message: "The requested SQLite capability is unavailable.",
                productCode: "sqlite.capability.not_implemented",
                retry: DatabaseRetryGuidance(action: .none)))

        #expect(failures.allSatisfy { $0 == expected })
        let cancellation = await session.cancel(DatabaseOperationID())
        #expect(cancellation.support == .unavailable)
        #expect(cancellation.disposition == .unavailable)

        await session.disconnect()
    }

    @Test func observesCancellationAndDeadlinesBeforeOpeningOrExecuting() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cancelledPath = directory.appendingPathComponent("cancelled.sqlite").path
        let cancelledDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: cancelledPath,
                    accessMode: .createIfMissing)))
        let cancellation = DatabaseAdapterCancellationSignal()
        await cancellation.cancel(.userRequested)
        let cancelledContext = SQLiteDatabaseAdapterFixtures.context(
            cancellation: cancellation)
        let connectCancellation = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(
                cancelledDefinition,
                context: cancelledContext)
        }
        #expect(connectCancellation == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: cancelledPath))

        let deadlinePath = directory.appendingPathComponent("deadline.sqlite").path
        let deadlineDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: deadlinePath,
                    accessMode: .createIfMissing)))
        let expiredContext = SQLiteDatabaseAdapterFixtures.context(
            deadline: Date(timeIntervalSinceNow: -1))
        let connectDeadline = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(
                deadlineDefinition,
                context: expiredContext)
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            connectDeadline,
            category: .timeout,
            productCode: "sqlite.deadline_exceeded")
        #expect(!FileManager.default.fileExists(atPath: deadlinePath))

        let session = try await SQLiteDatabaseAdapterFixtures.connect(
            try SQLiteDatabaseAdapterFixtures.definition())
        let operationCancellation = DatabaseAdapterCancellationSignal()
        await operationCancellation.cancel(.userRequested)
        let discoveryCancellation = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.discoverCapabilities(
                context: SQLiteDatabaseAdapterFixtures.context(
                    cancellation: operationCancellation))
        }
        #expect(discoveryCancellation == .cancelled)

        let discoveryDeadline = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.discoverCapabilities(
                context: SQLiteDatabaseAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: -1)))
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            discoveryDeadline,
            category: .timeout,
            productCode: "sqlite.deadline_exceeded")

        let page = try SQLiteDatabaseAdapterFixtures.pageRequest(
            connectionID: session.connection.id)
        let unsupportedCancellation = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.readPage(
                page,
                context: SQLiteDatabaseAdapterFixtures.context(
                    cancellation: operationCancellation))
        }
        #expect(unsupportedCancellation == .cancelled)

        await session.disconnect()
    }

    @Test func disconnectIsIdempotentAndReleasesTheDatabase() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("release.sqlite").path
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .createIfMissing)))
        let sessionValue = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let session = try #require(sessionValue as? SQLiteDatabaseAdapterSession)

        #expect(await session.lifecycleState() == .connected)
        #expect(await session.resourceIsOpen())
        await session.disconnect()
        #expect(await session.lifecycleState() == .disconnected)
        #expect(!(await session.resourceIsOpen()))
        await session.disconnect()
        #expect(await session.lifecycleState() == .disconnected)

        let failure = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.discoverCapabilities(
                context: SQLiteDatabaseAdapterFixtures.context())
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            failure,
            category: .connectionFailed,
            productCode: "sqlite.session.disconnected")

        try FileManager.default.removeItem(atPath: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func corruptDatabaseErrorsDoNotExposePathOrContents() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "private-database-marker"
        let path = directory.appendingPathComponent("\(secret).sqlite").path
        try Data(secret.utf8).write(to: URL(fileURLWithPath: path))
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(DatabaseSQLiteLocation(path: path)))
        let failure = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(definition)
        }

        SQLiteDatabaseAdapterFixtures.expectReported(
            failure,
            category: .connectionFailed,
            productCode: "sqlite.open_failed")
        guard case let .reported(envelope) = failure else { return }
        #expect(!envelope.message.contains(secret))
        #expect(!envelope.message.contains(path))
    }
}
