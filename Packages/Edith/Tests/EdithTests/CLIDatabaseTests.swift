import Foundation
import Testing

@testable import EdithCLI
@testable import EdithDatabase

private actor CLIDatabaseScriptedSender: DatabaseBrokerCommandSending {
    typealias Handler =
        @Sendable (DatabaseBrokerCommandRequest) throws
        -> DatabaseBrokerCommandResponse

    private let handler: Handler
    private var requests: [DatabaseBrokerCommandRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        requests.append(request)
        return try handler(request)
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] {
        requests
    }
}

private actor CLIDatabaseMCPRunRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func recordedCount() -> Int {
        count
    }
}

@Suite struct CLIDatabaseTests {
    private static let connectionUUID = UUID(
        uuidString: "36FC476B-28F7-4C1A-AE54-4B10D793FD0F")!
    private static let secretUUID = UUID(
        uuidString: "89E9D935-71EC-455A-A43A-C5301D7C6635")!
    private static let completeMetadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))

    @Test func databaseGroupsDefaultToConnectionListing() throws {
        #expect(try EdRoot.parseAsRoot(["database"]) is DatabaseConnectionsListCommand)
        #expect(
            try EdRoot.parseAsRoot(["database", "connections"])
                is DatabaseConnectionsListCommand)
        #expect(
            try EdRoot.parseAsRoot(["database", "connections", "ls"])
                is DatabaseConnectionsListCommand)
        #expect(try EdRoot.parseAsRoot(["database", "mcp"]) is DatabaseMCPCommand)
    }

    @Test func databaseCompletionRegistersRoutesFlagsAndFreeConnectionIDs() {
        func plan(_ words: [String], _ index: Int) -> CompletionResult {
            CompletionEngine.plan(
                CompletionRequest(words: words, index: index),
                machines: [],
                configKeys: [],
                extensionIDs: [])
        }

        #expect(plan(["ed", "dat"], 1).candidates == ["database"])
        #expect(
            plan(["ed", "database", ""], 2).candidates
                == ["connections", "capabilities", "mcp"])
        #expect(
            plan(["ed", "database", "connections", ""], 3).candidates
                == ["list", "ls", "get"])
        #expect(
            plan(["ed", "database", "connections", "list", "--fav"], 4).candidates
                == ["--favorites-only"])
        #expect(
            plan(["ed", "database", "connections", "get", "36fc"], 4).candidates.isEmpty)
    }

    @Test func databaseMCPStartsTheInjectedServerWithoutCLIOutput() async {
        let recorder = CLIDatabaseMCPRunRecorder()

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.runMCPServer = {
                await recorder.record()
            }
            let result = await CLIProbe.capture(["database", "mcp"])
            #expect(result.code == ExitCodes.success)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.isEmpty)
            #expect(await recorder.recordedCount() == 1)
        }
    }

    @Test func connectionListSendsExactSearchAndRendersSafeSummaries() async throws {
        let connection = try Self.connection()
        let sender = CLIDatabaseScriptedSender { request in
            .connectionList(
                .success(
                    DatabaseConnectionListResult(connections: [connection]),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "list",
                "--search", "orders",
                "--product", "postgresql",
                "--product", "redis",
                "--environment", "production",
                "--group", "payments",
                "--tag", "critical",
                "--tag", "reporting",
                "--favorites-only",
                "--order", "recently-updated",
                "--limit", "25",
                "--offset", "50",
                "--json",
            ])

            #expect(result.code == 0)
            #expect(result.stderr.isEmpty)
            let rows = try #require(result.array as? [[String: Any]])
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(row["id"] as? String == Self.connectionUUID.uuidString.lowercased())
            #expect(row["displayName"] as? String == "Primary orders")
            #expect(row["product"] as? String == "postgresql")
            #expect(row["favorite"] as? Bool == true)
            #expect(row["location"] == nil)
            #expect(row["authentication"] == nil)
            #expect(!result.stdout.contains(Self.secretUUID.uuidString))
            #expect(!result.stdout.contains("TOP_SECRET_DATABASE_SOURCE"))

            let requests = await sender.recordedRequests()
            #expect(requests.count == 1)
            let request = try #require(requests.first?.connectionListRequest)
            #expect(request.search.text == "orders")
            #expect(request.search.products == [.postgresql, .redis])
            #expect(request.search.environments == [.production])
            #expect(request.search.group == "payments")
            #expect(request.search.tags == ["critical", "reporting"])
            #expect(request.search.favoritesOnly)
            #expect(request.search.order == .recentlyUpdated)
            #expect(request.search.limit == 25)
            #expect(request.search.offset == 50)
        }
    }

    @Test func connectionListHumanOutputUsesBoundedOneLineCells() async throws {
        let connection = try Self.connection(displayName: "Primary\norders")
        let sender = CLIDatabaseScriptedSender { _ in
            .connectionList(
                .success(
                    DatabaseConnectionListResult(connections: [connection]),
                    metadata: Self.completeMetadata))
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture(["database", "connections"])
            #expect(result.code == 0)
            #expect(result.stdout.contains("ID"))
            #expect(result.stdout.contains("Primary orders"))
            #expect(result.stdout.contains("PostgreSQL"))
            #expect(!result.stdout.contains("TOP_SECRET_DATABASE_SOURCE"))
        }
    }

    @Test func connectionGetSendsExactIDAndOmitsCredentialMaterial() async throws {
        let connection = try Self.connection()
        let sender = CLIDatabaseScriptedSender { request in
            .connectionGet(
                .success(
                    DatabaseConnectionGetResult(connection: connection),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "get",
                Self.connectionUUID.uuidString, "--json",
            ])

            #expect(result.code == 0)
            let object = try #require(result.object)
            let authentication = try #require(object["authentication"] as? [String: Any])
            let tls = try #require(object["tls"] as? [String: Any])
            #expect(authentication["kind"] as? String == "usernameAndPassword")
            #expect(authentication["credentialsConfigured"] as? Bool == true)
            #expect(tls["certificateAuthorityConfigured"] as? Bool == true)
            #expect(tls["clientPrivateKeyConfigured"] as? Bool == true)
            #expect(!result.stdout.contains(Self.secretUUID.uuidString))
            #expect(!result.stdout.contains("TOP_SECRET_DATABASE_SOURCE"))
            #expect(!result.stdout.contains("password"))

            let requests = await sender.recordedRequests()
            let request = try #require(requests.first?.connectionGetRequest)
            #expect(request.connectionID.rawValue == Self.connectionUUID)
        }
    }

    @Test func missingConnectionUsesNotFoundWithoutPrintingJSON() async {
        let sender = CLIDatabaseScriptedSender { _ in
            .connectionGet(
                .success(
                    DatabaseConnectionGetResult(connection: nil),
                    metadata: Self.completeMetadata))
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "get",
                Self.connectionUUID.uuidString, "--json",
            ])
            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("no saved database connection"))
        }
    }

    @Test func capabilityRefreshSendsExactResolutionAndRendersReport() async throws {
        let report = Self.capabilityReport()
        let sender = CLIDatabaseScriptedSender { _ in
            .capabilities(
                .success(
                    DatabaseCapabilitiesResult(report: report, source: .discovered),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "capabilities", Self.connectionUUID.uuidString,
                "--refresh", "--json",
            ])

            #expect(result.code == 0)
            let object = try #require(result.object)
            let renderedReport = try #require(object["report"] as? [String: Any])
            let product = try #require(renderedReport["productIdentity"] as? [String: Any])
            let capabilities = try #require(renderedReport["capabilities"] as? [[String: Any]])
            #expect(
                object["connectionID"] as? String == Self.connectionUUID.uuidString.lowercased())
            #expect(object["source"] as? String == "discovered")
            #expect(product["product"] as? String == "postgresql")
            #expect(capabilities.count == 2)
            #expect((renderedReport["safetyLimitations"] as? [String]) == ["DDL is disabled."])

            let requests = await sender.recordedRequests()
            let request = try #require(requests.first?.capabilitiesRequest)
            #expect(request.connectionID.rawValue == Self.connectionUUID)
            #expect(request.resolution == .refresh)
        }
    }

    @Test func defaultCapabilityRequestAcceptsCachedDiscovery() async throws {
        let report = Self.capabilityReport()
        let sender = CLIDatabaseScriptedSender { _ in
            .capabilities(
                .success(
                    DatabaseCapabilitiesResult(report: report, source: .cached),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "capabilities", Self.connectionUUID.uuidString,
            ])
            #expect(result.code == 0)
            #expect(result.stdout.contains("product: PostgreSQL 17.4"))
            #expect(result.stdout.contains("data.browse"))
            #expect(result.stdout.contains("safety: DDL is disabled."))
            let requests = await sender.recordedRequests()
            let request = try #require(requests.first?.capabilitiesRequest)
            #expect(request.resolution == .cachedOrDiscover)
        }
    }

    @Test func invalidArgumentsDoNotReachTheBroker() async {
        let sender = CLIDatabaseScriptedSender { _ in
            throw DatabaseBrokerCommandClientError.unavailable
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let invalidID = await CLIProbe.capture([
                "database", "connections", "get", "not-a-uuid", "--json",
            ])
            let invalidLimit = await CLIProbe.capture([
                "database", "connections", "list", "--limit", "0", "--json",
            ])
            let invalidProduct = await CLIProbe.capture([
                "database", "connections", "list", "--product", "oracle", "--json",
            ])
            #expect(invalidID.code == ExitCodes.usage)
            #expect(invalidLimit.code == ExitCodes.usage)
            #expect(invalidProduct.code == ExitCodes.notFound)
            #expect((await sender.recordedRequests()).isEmpty)
        }
    }

    @Test func wrongResponseKindFailsClosed() async {
        let sender = CLIDatabaseScriptedSender { _ in
            .connectionList(
                .success(
                    DatabaseConnectionListResult(connections: []),
                    metadata: Self.completeMetadata))
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "get", Self.connectionUUID.uuidString,
                "--json",
            ])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stdout.isEmpty)
            #expect(
                result.stderr.contains(
                    "database broker returned database.connection.list for database.connection.get")
            )
        }
    }

    @Test func partialResultsFailClosedWithoutRenderingThePayload() async throws {
        let connection = try Self.connection()
        let sender = CLIDatabaseScriptedSender { _ in
            .connectionList(
                .partial(
                    DatabaseConnectionListResult(connections: [connection]),
                    metadata: DatabaseResultMetadata(
                        completeness: DatabaseResultCompleteness(
                            state: .partial,
                            reason: "one\nbackend failed"))))
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "list", "--json",
            ])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("partial results"))
            #expect(result.stderr.contains("one backend failed"))
        }
    }

    @Test func staleResultsFailClosedEvenWhenTheBrokerMarksSuccess() async {
        let sender = CLIDatabaseScriptedSender { _ in
            .connectionList(
                .success(
                    DatabaseConnectionListResult(connections: []),
                    metadata: DatabaseResultMetadata(
                        completeness: DatabaseResultCompleteness(
                            state: .stale,
                            reason: "cache expired"))))
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "list", "--json",
            ])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("stale results"))
            #expect(result.stderr.contains("cache expired"))
        }
    }

    @Test func partialFailuresFailClosedEvenWithCompleteStatus() async {
        let sender = CLIDatabaseScriptedSender { _ in
            .connectionList(
                .success(
                    DatabaseConnectionListResult(connections: []),
                    metadata: DatabaseResultMetadata(
                        completeness: DatabaseResultCompleteness(state: .complete),
                        partialFailures: [
                            DatabasePartialFailure(
                                itemIdentifier: "connection-1",
                                error: DatabaseErrorEnvelope(
                                    category: .partialFailure,
                                    message: "one item failed"))
                        ])))
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "list", "--json",
            ])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("incomplete results"))
        }
    }

    @Test func completeResultWarningsRemainVisibleBesideJSON() async {
        let sender = CLIDatabaseScriptedSender { _ in
            .connectionList(
                .success(
                    DatabaseConnectionListResult(connections: []),
                    metadata: DatabaseResultMetadata(
                        completeness: DatabaseResultCompleteness(state: .complete),
                        warnings: [
                            DatabaseWarning(
                                code: "broker.cache",
                                message: "Using cached\nmetadata.",
                                severity: .caution)
                        ])))
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "list", "--json",
            ])
            #expect(result.code == ExitCodes.success)
            #expect(result.stdout == "[]\n")
            #expect(result.stderr == "warning [caution] broker.cache: Using cached metadata.\n")
        }
    }

    @Test func brokerTransportFailuresUseStableDiagnostics() async {
        let cases: [(DatabaseBrokerCommandClientError, Int32, String)] = [
            (.invalidRequest, ExitCodes.usage, "rejected the request"),
            (.timedOut, ExitCodes.unavailable, "request timed out"),
            (.unavailable, ExitCodes.unavailable, "broker is unavailable"),
            (.unsafePeer, ExitCodes.unavailable, "identity could not be verified"),
            (.outcomeUnknown, ExitCodes.unavailable, "response was interrupted"),
        ]

        for (error, code, message) in cases {
            await CLIProbe.inWorld { _ in
                let sender = CLIDatabaseScriptedSender { _ in throw error }
                DatabaseCLIEnvironment.makeSender = { sender }
                let result = await CLIProbe.capture([
                    "database", "connections", "list", "--json",
                ])
                #expect(result.code == code)
                #expect(result.stdout.isEmpty)
                #expect(result.stderr.contains(message))
            }
        }
    }

    @Test func brokerCommandErrorsKeepStableExitCategories() async {
        let notFound = DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The database connection was not found.")
        let unavailable = DatabaseErrorEnvelope(
            category: .authenticationFailed,
            message: "Database authentication failed.",
            retry: DatabaseRetryGuidance(
                action: .reauthenticate,
                message: "Replace the saved credential."))
        let errors = [
            (notFound, ExitCodes.notFound, "connection was not found"),
            (unavailable, ExitCodes.unavailable, "authentication failed"),
        ]

        for (error, code, message) in errors {
            await CLIProbe.inWorld { _ in
                let sender = CLIDatabaseScriptedSender { _ in
                    .capabilities(.failure(error, metadata: Self.completeMetadata))
                }
                DatabaseCLIEnvironment.makeSender = { sender }
                let result = await CLIProbe.capture([
                    "database", "capabilities", Self.connectionUUID.uuidString, "--json",
                ])
                #expect(result.code == code)
                #expect(result.stdout.isEmpty)
                #expect(result.stderr.localizedCaseInsensitiveContains(message))
            }
        }
    }

    private static func connection(
        displayName: String = "Primary orders"
    ) throws -> DatabaseConnectionDefinition {
        let secret = DatabaseSecretReference(
            identifier: secretUUID,
            purpose: .password)
        let certificateAuthority = DatabaseResourceReference(
            identifier: secretUUID,
            kind: .certificateAuthority)
        return DatabaseConnectionDefinition(
            id: DatabaseConnectionID(rawValue: connectionUUID),
            displayName: displayName,
            productHint: .postgresql,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "db.internal",
                    port: try DatabasePort(5_432),
                    role: .primary)
            ]),
            username: "edith",
            namespaces: DatabaseNamespaceDefaults(
                catalog: "orders-catalog",
                schema: "public",
                database: "orders"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [secret],
                source: "TOP_SECRET_DATABASE_SOURCE"),
            tls: DatabaseTLSConfiguration(
                mode: .required,
                verification: .full,
                serverName: "db.internal",
                certificateAuthority: certificateAuthority,
                clientPrivateKey: secret),
            tunnel: DatabaseTunnelDefinition(
                machineIdentifier: "tuf",
                remoteEndpoint: DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(5_432)),
                requestedLocalPort: try DatabasePort(15_432)),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4),
                idleTimeout: try DatabaseTimeout(milliseconds: 60_000)),
            readOnlyPolicy: .required,
            productionPolicy: .requireMutationPreview,
            environment: DatabaseEnvironmentMetadata(
                kind: .production,
                label: "production",
                protection: .confirmationRequired),
            group: "payments",
            tags: ["critical", "reporting"],
            color: "red",
            isFavorite: true,
            options: [
                DatabaseNonSecretOption(
                    name: "application_name",
                    value: .string("edith"))
            ],
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastTestedAt: Date(timeIntervalSince1970: 3_000),
            lastUsedAt: Date(timeIntervalSince1970: 4_000))
    }

    private static func capabilityReport() -> DatabaseCapabilityReport {
        DatabaseCapabilityReport(
            productIdentity: DatabaseProductIdentity(
                product: .postgresql,
                version: DatabaseVersion(string: "17.4", major: 17, minor: 4),
                distribution: "PostgreSQL",
                topology: DatabaseTopology(
                    kind: .standalone,
                    name: "primary",
                    localRole: "primary",
                    nodeCount: 1,
                    attributes: [DatabaseStringAttribute(name: "region", value: "local")]),
                serverIdentifier: "postgres-primary",
                modules: [DatabaseExtensionIdentity(name: "pg_stat_statements", version: "1.11")],
                compatibilityNotes: ["Native PostgreSQL protocol."]),
            capabilities: [
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available,
                    limits: [
                        DatabaseCapabilityLimit(name: "pageRecords", value: 1_000, unit: "rows")
                    ]),
                DatabaseCapabilityStatus(
                    id: .delete,
                    requirement: .sharedRequired,
                    availability: .unavailable,
                    reason: DatabaseCapabilityUnavailableReason(
                        category: .permission,
                        message: "DELETE permission is unavailable.",
                        missingPermissions: ["DELETE"])),
            ],
            permissions: [
                DatabasePermissionStatus(name: "SELECT", granted: true, scope: "orders")
            ],
            pagingModes: [.keyset],
            mutationModes: [.transactionalBatch],
            transactionModes: [.explicit],
            cancellationModes: [.protocolCancellation],
            importFormats: [.csv],
            exportFormats: [.csv, .jsonLines],
            explainModes: [.logical, .analyzed],
            safetyLimitations: ["DDL is disabled."],
            discoveredAt: Date(timeIntervalSince1970: 5_000),
            expiresAt: Date(timeIntervalSince1970: 5_300))
    }
}
