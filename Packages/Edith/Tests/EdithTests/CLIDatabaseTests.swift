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
    private static let queryUUID = UUID(
        uuidString: "7565FB65-A823-4F88-93F3-61CD6558E590")!
    private static let mutationOperationUUID = UUID(
        uuidString: "CE33CE42-91CB-438B-BB10-8130315A241B")!
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
        #expect(
            try EdRoot.parseAsRoot(["database", "saved-queries"])
                is DatabaseSavedQueriesListCommand)
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
                == [
                    "connections", "saved-queries", "capabilities", "connect", "disconnect",
                    "browse", "query", "mutations", "operations", "mcp",
                ])
        #expect(
            plan(["ed", "database", "connections", ""], 3).candidates
                == [
                    "list", "ls", "get", "add", "test", "edit", "duplicate", "rename",
                    "delete",
                ])
        #expect(
            plan(["ed", "database", "saved-queries", ""], 3).candidates
                == ["list", "ls", "get", "save", "duplicate", "rename", "delete"])
        #expect(
            plan(["ed", "database", "connections", "list", "--fav"], 4).candidates
                == ["--favorites-only"])
        #expect(
            plan(["ed", "database", "connections", "get", "36fc"], 4).candidates.isEmpty)
        #expect(
            plan(["ed", "database", "browse", "id", "--cont"], 4).candidates
                == ["--continuation"])
        #expect(
            plan(["ed", "database", "query", "id", "--nd"], 4).candidates == ["--ndjson"])
        #expect(
            plan(["ed", "database", "mutations", ""], 3).candidates
                == [
                    "row-request", "key-request", "preview", "apply", "status", "cancel",
                    "outcome",
                ])
    }

    @Test func databaseExecutionRoutesParse() throws {
        #expect(
            try EdRoot.parseAsRoot(["database", "connect", Self.connectionUUID.uuidString])
                is DatabaseConnectCommand)
        #expect(
            try EdRoot.parseAsRoot(["database", "disconnect", Self.connectionUUID.uuidString])
                is DatabaseDisconnectCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "browse", Self.connectionUUID.uuidString, "--path", "orders",
            ]) is DatabaseBrowseCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "query", Self.connectionUUID.uuidString, "--file", "query.sql",
            ]) is DatabaseQueryCommand)
        #expect(
            try EdRoot.parseAsRoot(["database", "operations"])
                is DatabaseOperationsListCommand)
        #expect(
            try EdRoot.parseAsRoot(["database", "operations", "cancel", UUID().uuidString])
                is DatabaseOperationsCancelCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "connections", "test", Self.connectionUUID.uuidString,
            ]) is DatabaseConnectionsTestCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "connections", "edit", Self.connectionUUID.uuidString,
                "--environment", "staging",
            ]) is DatabaseConnectionsEditCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "connections", "delete", Self.connectionUUID.uuidString, "--yes",
            ]) is DatabaseConnectionsDeleteCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "saved-queries", "save", "orders", "--language", "sql",
            ]) is DatabaseSavedQueriesSaveCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "saved-queries", "delete", Self.queryUUID.uuidString, "--yes",
            ]) is DatabaseSavedQueriesDeleteCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "mutations", "row-request", Self.connectionUUID.uuidString,
                "--action", "update", "--path", "public", "--path", "orders",
                "--identity", "identity.json", "--values", "values.json",
            ]) is DatabaseMutationRowRequestCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "mutations", "key-request", Self.connectionUUID.uuidString,
                "--action", "update", "--key", "session:1", "--value", "ready",
            ]) is DatabaseMutationKeyRequestCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "mutations", "preview", "--request", "mutation.json",
            ]) is DatabaseMutationPreviewCommand)
        #expect(
            try EdRoot.parseAsRoot([
                "database", "mutations", "apply", "--request", "mutation.json",
                "--confirmation", "preview.json", "--yes",
            ]) is DatabaseMutationApplyCommand)
    }

    @Test func connectionEditPreservesTransportAndCredentials() async throws {
        let connection = try Self.connection()
        let sender = CLIDatabaseScriptedSender { request in
            switch request {
            case .connectionGet:
                return .connectionGet(
                    .success(
                        DatabaseConnectionGetResult(connection: connection),
                        metadata: Self.completeMetadata))
            case .connectionEdit(let edit):
                return .connectionEdit(
                    .success(
                        DatabaseConnectionEditResult(connection: edit.connection),
                        metadata: Self.completeMetadata))
            default:
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "edit", Self.connectionUUID.uuidString,
                "--environment", "staging", "--environment-label", "pre-release",
                "--protection", "read-only", "--read-only", "required",
                "--production-policy", "prohibit-mutations", "--clear-group",
                "--clear-tags", "--clear-color", "--not-favorite", "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            #expect(!result.stdout.contains(Self.secretUUID.uuidString))
            let requests = await sender.recordedRequests()
            #expect(requests.count == 2)
            let edit = try #require(requests.last?.connectionEditRequest)
            #expect(edit.connectionID.rawValue == Self.connectionUUID)
            #expect(edit.connection.location == connection.location)
            #expect(edit.connection.authentication == connection.authentication)
            #expect(edit.connection.tls == connection.tls)
            #expect(edit.connection.environment.kind == .staging)
            #expect(edit.connection.environment.label == "pre-release")
            #expect(edit.connection.environment.protection == .readOnly)
            #expect(edit.connection.productionPolicy == .prohibitMutations)
            #expect(edit.connection.group == nil)
            #expect(edit.connection.tags.isEmpty)
            #expect(edit.connection.color == nil)
            #expect(!edit.connection.isFavorite)
        }
    }

    @Test func connectionDuplicateAndDeleteKeepCredentialReferencesPrivate() async throws {
        let connection = try Self.connection()
        let reference = try #require(connection.authentication.secretReferences.first)
        let sender = CLIDatabaseScriptedSender { request in
            switch request {
            case .connectionDuplicate:
                return .connectionDuplicate(
                    .success(
                        DatabaseConnectionDuplicateResult(
                            sourceConnectionID: connection.id,
                            connection: connection,
                            sharesCredentials: true,
                            sharedCredentialReferences: [reference]),
                        metadata: Self.completeMetadata))
            case .connectionDelete(let delete):
                return .connectionDelete(
                    .success(
                        DatabaseConnectionDeleteResult(
                            connectionID: delete.connectionID,
                            deleted: true,
                            disconnected: true),
                        metadata: Self.completeMetadata))
            default:
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let duplicate = await CLIProbe.capture([
                "database", "connections", "duplicate", Self.connectionUUID.uuidString,
                "orders copy", "--json",
            ])
            #expect(duplicate.code == ExitCodes.success)
            #expect(duplicate.object?["sharesCredentials"] as? Bool == true)
            #expect(duplicate.object?["sharedCredentialCount"] as? Int == 1)
            #expect(!duplicate.stdout.contains(Self.secretUUID.uuidString))

            let refused = await CLIProbe.capture([
                "database", "connections", "delete", Self.connectionUUID.uuidString,
            ])
            #expect(refused.code == ExitCodes.usage)

            let deleted = await CLIProbe.capture([
                "database", "connections", "delete", Self.connectionUUID.uuidString,
                "--yes", "--json",
            ])
            #expect(deleted.code == ExitCodes.success)
            #expect(deleted.object?["deleted"] as? Bool == true)
            #expect(deleted.object?["disconnected"] as? Bool == true)
            #expect((await sender.recordedRequests()).count == 2)
        }
    }

    @Test func savedQueryListSendsBoundedFiltersWithoutBodies() async throws {
        let query = Self.savedQuery()
        let sender = CLIDatabaseScriptedSender { request in
            guard case .savedQueryList = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .savedQueryList(
                .success(
                    DatabaseSavedQueryListResult(queries: [query]),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "saved-queries", "list", "--search", "orders",
                "--connection", Self.connectionUUID.uuidString,
                "--language", "sql", "--tag", "reporting", "--favorites-only",
                "--order", "name", "--limit", "25", "--offset", "10", "--json",
            ])

            #expect(result.code == ExitCodes.success)
            let rows = try #require(result.array as? [[String: Any]])
            #expect(rows.first?["name"] as? String == "Recent orders")
            #expect(rows.first?["text"] == nil)
            #expect(!result.stdout.contains(query.text))
            let request = try #require(await sender.recordedRequests().first?.savedQueryListRequest)
            #expect(request.search.connectionID?.rawValue == Self.connectionUUID)
            #expect(request.search.languages == [.sql])
            #expect(request.search.tags == ["reporting"])
            #expect(request.search.favoritesOnly)
            #expect(request.search.order == .name)
            #expect(request.search.limit == 25)
            #expect(request.search.offset == 10)
        }
    }

    @Test func savedQuerySaveReadsInputAndRoutesExactDefinition() async throws {
        let sender = CLIDatabaseScriptedSender { request in
            guard case .savedQuerySave(let save) = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .savedQuerySave(
                .success(
                    DatabaseSavedQuerySaveResult(query: save.query, created: true),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            DatabaseCLIEnvironment.readQueryText = { path in
                #expect(path == "orders.sql")
                return "select id from public.orders"
            }
            let result = await CLIProbe.capture([
                "database", "saved-queries", "save", "Recent orders",
                "--connection", Self.connectionUUID.uuidString,
                "--language", "sql", "--file", "orders.sql",
                "--tag", "reporting", "--favorite", "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.object?["created"] as? Bool == true)
            let request = try #require(await sender.recordedRequests().first?.savedQuerySaveRequest)
            #expect(request.query.connectionID?.rawValue == Self.connectionUUID)
            #expect(request.query.name == "Recent orders")
            #expect(request.query.language == .sql)
            #expect(request.query.text == "select id from public.orders")
            #expect(request.query.tags == ["reporting"])
            #expect(request.query.isFavorite)
        }
    }

    @Test func savedQueryManagementRoutesExactIdentifiers() async throws {
        let query = Self.savedQuery()
        let sender = CLIDatabaseScriptedSender { request in
            switch request {
            case .savedQueryGet:
                return .savedQueryGet(
                    .success(
                        DatabaseSavedQueryGetResult(query: query),
                        metadata: Self.completeMetadata))
            case .savedQueryDuplicate:
                return .savedQueryDuplicate(
                    .success(
                        DatabaseSavedQueryDuplicateResult(
                            sourceQueryID: query.id,
                            query: query),
                        metadata: Self.completeMetadata))
            case .savedQueryRename:
                return .savedQueryRename(
                    .success(
                        DatabaseSavedQueryRenameResult(query: query),
                        metadata: Self.completeMetadata))
            case .savedQueryDelete(let delete):
                return .savedQueryDelete(
                    .success(
                        DatabaseSavedQueryDeleteResult(
                            queryID: delete.queryID,
                            deleted: true),
                        metadata: Self.completeMetadata))
            default:
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let get = await CLIProbe.capture([
                "database", "saved-queries", "get", Self.queryUUID.uuidString, "--json",
            ])
            let duplicate = await CLIProbe.capture([
                "database", "saved-queries", "duplicate", Self.queryUUID.uuidString,
                "orders copy", "--json",
            ])
            let rename = await CLIProbe.capture([
                "database", "saved-queries", "rename", Self.queryUUID.uuidString,
                "orders renamed", "--json",
            ])
            let refused = await CLIProbe.capture([
                "database", "saved-queries", "delete", Self.queryUUID.uuidString,
            ])
            let delete = await CLIProbe.capture([
                "database", "saved-queries", "delete", Self.queryUUID.uuidString,
                "--yes", "--json",
            ])

            #expect(get.code == ExitCodes.success)
            #expect(get.object?["text"] as? String == query.text)
            #expect(duplicate.code == ExitCodes.success)
            #expect(rename.code == ExitCodes.success)
            #expect(refused.code == ExitCodes.usage)
            #expect(delete.code == ExitCodes.success)
            #expect((await sender.recordedRequests()).count == 4)
        }
    }

    @Test func mutationRowRequestBuildsBoundPostgreSQLUpdate() async throws {
        let identity = try #require(Self.mutation().target.record)
        let values = [
            DatabaseObjectField(name: "note", value: .string("verified"))
        ]
        let identityDocument = try Self.encoded(identity)
        let valuesDocument = try Self.encoded(values)

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.readQueryText = { path in
                switch path {
                case "identity.json": identityDocument
                case "values.json": valuesDocument
                default: throw CLIFailure.usage("unexpected row mutation document")
                }
            }
            let result = await CLIProbe.capture([
                "database", "mutations", "row-request", Self.connectionUUID.uuidString,
                "--action", "update", "--path", "public", "--path", "orders",
                "--identity", "identity.json", "--values", "values.json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            let request = try JSONDecoder().decode(
                DatabaseDestructiveRequest.self,
                from: Data(result.stdout.utf8))
            #expect(request.target.record == identity)
            guard case .relational(let product, let statement, let parameters) = request.payload
            else {
                Issue.record("expected relational PostgreSQL mutation")
                return
            }
            #expect(product == .postgresql)
            #expect(statement.contains("UPDATE \"public\".\"orders\""))
            #expect(parameters.map(\.name) == ["note"])
        }
    }

    @Test func mutationKeyRequestBuildsBoundValkeyUpdate() async throws {
        try await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture([
                "database", "mutations", "key-request", Self.connectionUUID.uuidString,
                "--action", "update", "--product", "valkey", "--logical-database", "2",
                "--key", "session:1", "--value", "ready", "--ttl-milliseconds=-1",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            let request = try JSONDecoder().decode(
                DatabaseDestructiveRequest.self,
                from: Data(result.stdout.utf8))
            #expect(request.target.object?.kind == .keyspace)
            #expect(request.target.object?.path == ["2"])
            #expect(request.target.record?.components.first?.value == .string("session:1"))
            guard case .keyspace(let product, let command, let parameters) = request.payload else {
                Issue.record("expected Redis-compatible key mutation")
                return
            }
            #expect(product == .valkey)
            #expect(command == "SET")
            #expect(parameters.map(\.name) == ["key", "value", "ttlPolicy"])
            #expect(parameters.last?.value == .string("persistent"))
        }
    }

    @Test func mutationPreviewReadsBoundedRequestAndEmitsReusableConfirmation() async throws {
        let mutation = Self.mutation()
        let preview = try Self.mutationPreview()
        let document = try Self.encoded(mutation)
        let sender = CLIDatabaseScriptedSender { request in
            guard case .mutationPreview = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .mutationPreview(
                .success(
                    DatabaseMutationPreviewResult(preview: preview),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            DatabaseCLIEnvironment.readQueryText = { path in
                #expect(path == "mutation.json")
                return document
            }
            let result = await CLIProbe.capture([
                "database", "mutations", "preview", "--request", "mutation.json",
                "--timeout-milliseconds", "5000", "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.object?["action"] as? String == "update")
            #expect(result.object?["scope"] as? String == "singleRecord")
            #expect(result.object?["token"] as? String == "short-lived-token")
            let required = try #require(
                result.object?["requiredConfirmation"] as? [String: Any])
            #expect(required["text"] as? String == "Primary orders / public.orders")
            let request = try #require(
                await sender.recordedRequests().first?.mutationPreviewRequest)
            #expect(request.mutation == mutation)
            #expect(request.operation.deadline != nil)
        }
    }

    @Test func mutationApplyRequiresFilesAndBindsExactPreview() async throws {
        let mutation = Self.mutation()
        let mutationDocument = try Self.encoded(mutation)
        let confirmationDocument =
            """
            {"token":"short-lived-token","requiredConfirmation":{"text":"Primary orders / public.orders"}}
            """
        let sender = CLIDatabaseScriptedSender { request in
            guard case .mutationApply = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .mutationApply(
                .success(
                    DatabaseMutationApplyResult(
                        disposition: .completed,
                        effect: .applied,
                        affectedRecords: DatabaseCountMetadata(value: 1, accuracy: .exact)),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            DatabaseCLIEnvironment.readQueryText = { path in
                switch path {
                case "mutation.json": mutationDocument
                case nil: confirmationDocument
                default: throw CLIFailure.usage("unexpected mutation document")
                }
            }

            let refused = await CLIProbe.capture([
                "database", "mutations", "apply", "--request", "mutation.json",
                "--confirmation", "preview.json",
            ])
            #expect(refused.code == ExitCodes.usage)

            let result = await CLIProbe.capture([
                "database", "mutations", "apply", "--request", "mutation.json",
                "--confirmation", "-", "--yes", "--json",
            ])
            #expect(result.code == ExitCodes.success)
            #expect(result.object?["effect"] as? String == "applied")
            #expect(
                result.object?["connectionID"] as? String
                    == Self.connectionUUID.uuidString.lowercased())
            let request = try #require(
                await sender.recordedRequests().first?.mutationApplyRequest)
            #expect(request.mutation == mutation)
            #expect(request.token.rawValue == "short-lived-token")
            #expect(request.confirmationText == "Primary orders / public.orders")
        }
    }

    @Test func mutationReconciliationUsesAcceptedReceiptAndDurableOutcome() async throws {
        let accepted = DatabaseAcceptedMutation(
            operationID: DatabaseOperationID(rawValue: Self.mutationOperationUUID),
            serverOperationIdentifier: "postgres-backend-42")
        let receipt =
            """
            {"connectionID":"\(Self.connectionUUID.uuidString)","acceptedMutation":{"operationID":"\(Self.mutationOperationUUID.uuidString)","serverOperationIdentifier":"postgres-backend-42"}}
            """
        let outcome = DatabaseMutationApplyResult(
            disposition: .completed,
            effect: .applied,
            affectedRecords: DatabaseCountMetadata(value: 1, accuracy: .exact))
        let sender = CLIDatabaseScriptedSender { request in
            switch request {
            case .mutationStatus:
                return .mutationStatus(
                    .success(
                        DatabaseMutationStatusResult(
                            acceptedMutation: accepted,
                            state: .running,
                            progress: .determinate(completed: 1, total: 2, unit: .steps)),
                        metadata: Self.completeMetadata))
            case .mutationCancel:
                return .mutationCancel(
                    .success(
                        DatabaseMutationCancelResult(
                            acceptedMutation: accepted,
                            disposition: .accepted),
                        metadata: Self.completeMetadata))
            case .mutationOutcomeGet:
                return .mutationOutcomeGet(
                    .success(
                        DatabaseMutationOutcomeGetResult(operation: nil, outcome: outcome),
                        metadata: Self.completeMetadata))
            default:
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            DatabaseCLIEnvironment.readQueryText = { path in
                #expect(path == "receipt.json")
                return receipt
            }
            let status = await CLIProbe.capture([
                "database", "mutations", "status", "--receipt", "receipt.json", "--json",
            ])
            let refused = await CLIProbe.capture([
                "database", "mutations", "cancel", "--receipt", "receipt.json",
            ])
            let cancel = await CLIProbe.capture([
                "database", "mutations", "cancel", "--receipt", "receipt.json", "--yes",
                "--json",
            ])
            let durable = await CLIProbe.capture([
                "database", "mutations", "outcome", Self.mutationOperationUUID.uuidString,
                "--json",
            ])

            #expect(status.code == ExitCodes.success)
            #expect(status.object?["state"] as? String == "running")
            #expect(refused.code == ExitCodes.usage)
            #expect(cancel.code == ExitCodes.success)
            #expect(cancel.object?["disposition"] as? String == "accepted")
            #expect(durable.code == ExitCodes.success)
            let renderedOutcome = try #require(durable.object?["outcome"] as? [String: Any])
            #expect(renderedOutcome["effect"] as? String == "applied")

            let requests = await sender.recordedRequests()
            #expect(requests.count == 3)
            let statusRequest = try #require(requests[0].mutationStatusRequest)
            #expect(statusRequest.connectionID.rawValue == Self.connectionUUID)
            #expect(statusRequest.acceptedMutation == accepted)
            let cancelRequest = try #require(requests[1].mutationCancelRequest)
            #expect(cancelRequest.acceptedMutation == accepted)
            #expect(
                requests[2].mutationOutcomeGetRequest?.operationID.rawValue
                    == Self.mutationOperationUUID)
        }
    }

    @Test func operationListSendsExactFiltersAndSafeJSON() async throws {
        let operation = try Self.operation()
        let sender = CLIDatabaseScriptedSender { request in
            guard case .operationList = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .operationList(
                .success(
                    DatabaseOperationListResult(operations: [operation]),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "operations", "list",
                "--connection", Self.connectionUUID.uuidString,
                "--state", "running", "--state", "cancelling",
                "--kind", "database.query", "--before", "2026-08-31T10:00:00Z",
                "--limit", "40", "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            let operations = try #require(result.array as? [[String: Any]])
            #expect(operations.first?["state"] as? String == "running")
            #expect(operations.first?["kind"] as? String == "database.query")
            #expect(!result.stdout.contains(Self.secretUUID.uuidString))

            let request = try #require(await sender.recordedRequests().first?.operationListRequest)
            #expect(request.search.connectionID?.rawValue == Self.connectionUUID)
            #expect(request.search.states == [.running, .cancelling])
            #expect(request.search.kinds == [DatabaseOperationKind(rawValue: "database.query")])
            #expect(
                request.search.before == ISO8601DateFormatter().date(from: "2026-08-31T10:00:00Z"))
            #expect(request.search.limit == 40)
        }
    }

    @Test func operationCancelReturnsDispositionAndExactID() async throws {
        let operation = try Self.operation()
        let sender = CLIDatabaseScriptedSender { request in
            guard case .operationCancel(let cancel) = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .operationCancel(
                .success(
                    DatabaseOperationCancelResult(
                        operationID: cancel.operationID,
                        disposition: .accepted,
                        cancellationSupport: .serverSide,
                        operation: operation),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "operations", "cancel",
                operation.id.rawValue.uuidString, "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            #expect(result.object?["disposition"] as? String == "accepted")
            #expect(result.object?["cancellationSupport"] as? String == "serverSide")
            let request = try #require(
                await sender.recordedRequests().first?.operationCancelRequest)
            #expect(request.operationID == operation.id)
        }
    }

    @Test func missingOperationUsesNotFoundWithoutOutput() async {
        let sender = CLIDatabaseScriptedSender { request in
            guard case .operationGet = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .operationGet(
                .success(
                    DatabaseOperationGetResult(operation: nil),
                    metadata: Self.completeMetadata))
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "operations", "get", UUID().uuidString, "--json",
            ])
            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("operation was not found"))
        }
    }

    @Test func connectSendsExactIDDeadlineAndSafeJSON() async throws {
        let connection = try Self.connection()
        let sender = CLIDatabaseScriptedSender { request in
            guard case .connect = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .connect(
                .success(
                    DatabaseConnectResult(
                        connection: connection.identity,
                        productIdentity: Self.capabilityReport().productIdentity,
                        capabilities: Self.capabilityReport(),
                        connectedAt: Date(timeIntervalSince1970: 6_000)),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let started = Date()
            let result = await CLIProbe.capture([
                "database", "connect", Self.connectionUUID.uuidString,
                "--timeout-milliseconds", "5000", "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            #expect(
                result.object?["connectionID"] as? String
                    == Self.connectionUUID.uuidString.lowercased())
            #expect(result.object?["product"] as? String == "postgresql")
            #expect(!result.stdout.contains(Self.secretUUID.uuidString))

            let request = try #require(await sender.recordedRequests().first?.connectRequest)
            #expect(request.connectionID.rawValue == Self.connectionUUID)
            let deadline = try #require(request.operation.deadline)
            #expect(deadline.timeIntervalSince(started) >= 4.5)
            #expect(deadline.timeIntervalSince(started) <= 5.5)
        }
    }

    @Test func savedConnectionTestLoadsDefinitionAndKeepsSecretsOutOfOutput() async throws {
        let connection = try Self.connection()
        let sender = CLIDatabaseScriptedSender { request in
            switch request {
            case .connectionGet:
                return .connectionGet(
                    .success(
                        DatabaseConnectionGetResult(connection: connection),
                        metadata: Self.completeMetadata))
            case .connectionTest(let test):
                return .connectionTest(
                    .success(
                        DatabaseConnectionTestResult(
                            connection: test.connection.identity,
                            productIdentity: Self.capabilityReport().productIdentity,
                            capabilities: Self.capabilityReport(),
                            latencyMilliseconds: 18,
                            testedAt: Date(timeIntervalSince1970: 8_000)),
                        metadata: Self.completeMetadata))
            default:
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "connections", "test", Self.connectionUUID.uuidString,
                "--timeout-milliseconds", "10000", "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            #expect(result.object?["latencyMilliseconds"] as? Int == 18)
            #expect(result.object?["product"] as? String == "postgresql")
            #expect(!result.stdout.contains(Self.secretUUID.uuidString))
            #expect(!result.stdout.contains("TOP_SECRET_DATABASE_SOURCE"))

            let requests = await sender.recordedRequests()
            #expect(requests.count == 2)
            #expect(
                requests.first?.connectionGetRequest?.connectionID.rawValue == Self.connectionUUID)
            let tested = try #require(requests.last?.connectionTestRequest)
            #expect(tested.connection == connection)
            #expect(tested.operation.deadline != nil)
        }
    }

    @Test func browseSendsQualifiedTargetAndRendersNDJSONPage() async throws {
        let sender = CLIDatabaseScriptedSender { request in
            guard case .browse = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .browse(
                .success(
                    DatabaseBrowseResult(page: Self.page()),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let result = await CLIProbe.capture([
                "database", "browse", Self.connectionUUID.uuidString,
                "--kind", "table", "--path", "public", "--path", "orders",
                "--limit", "25", "--continuation", "previous-page", "--ndjson",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            #expect(result.stdoutLines.count == 2)
            let record =
                try JSONSerialization.jsonObject(
                    with: Data(result.stdoutLines[0].utf8)) as? [String: Any]
            let page =
                try JSONSerialization.jsonObject(
                    with: Data(result.stdoutLines[1].utf8)) as? [String: Any]
            #expect(record?["type"] as? String == "record")
            #expect(page?["type"] as? String == "page")
            #expect(page?["nextContinuation"] as? String == "next-page")

            let request = try #require(await sender.recordedRequests().first?.browseRequest)
            #expect(request.target.connectionID.rawValue == Self.connectionUUID)
            #expect(request.target.object?.kind == .table)
            #expect(request.target.object?.path == ["public", "orders"])
            #expect(request.page.pageSize.value == 25)
            #expect(request.page.continuation?.rawValue == "previous-page")
        }
    }

    @Test func queryReadsFileInputAndRendersBoundedJSON() async throws {
        let sender = CLIDatabaseScriptedSender { request in
            guard case .query = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .query(
                .success(
                    DatabaseQueryResult(
                        page: Self.page(note: String(repeating: "x", count: 40_000))),
                    metadata: Self.completeMetadata))
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            DatabaseCLIEnvironment.readQueryText = { path in
                guard path == "query.sql" else {
                    throw CLIFailure.usage("unexpected query path")
                }
                return "select * from public.orders"
            }
            let result = await CLIProbe.capture([
                "database", "query", Self.connectionUUID.uuidString,
                "--file", "query.sql", "--language", "sql", "--limit", "10", "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            let records = try #require(result.object?["records"] as? [[String: Any]])
            let fields = try #require(records.first?["fields"] as? [[String: Any]])
            let note = try #require(fields.first(where: { $0["name"] as? String == "note" }))
            let value = try #require(note["value"] as? [String: Any])
            #expect(value["truncated"] as? Bool == true)
            #expect(value["characters"] as? Int == 40_000)

            let request = try #require(await sender.recordedRequests().first?.queryRequest)
            #expect(request.command == "select * from public.orders")
            #expect(request.language == .sql)
            #expect(request.target.object == nil)
            #expect(request.page.pageSize.value == 10)
        }
    }

    @Test func executionValidationDoesNotReachBroker() async {
        let sender = CLIDatabaseScriptedSender { _ in
            throw DatabaseBrokerCommandClientError.invalidRequest
        }

        await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            let cases = [
                ["database", "browse", Self.connectionUUID.uuidString],
                [
                    "database", "browse", Self.connectionUUID.uuidString, "--path", "orders",
                    "--limit", "0",
                ],
                [
                    "database", "connect", Self.connectionUUID.uuidString,
                    "--timeout-milliseconds", "0",
                ],
                [
                    "database", "query", Self.connectionUUID.uuidString, "--json", "--ndjson",
                ],
                ["database", "operations", "list", "--limit", "1001"],
                ["database", "operations", "get", "not-a-uuid"],
            ]
            for arguments in cases {
                let result = await CLIProbe.capture(arguments)
                #expect(result.code == ExitCodes.usage)
                #expect(result.stdout.isEmpty)
                #expect(!result.stderr.isEmpty)
            }
            #expect(await sender.recordedRequests().isEmpty)
        }
    }

    @Test func connectionAddTestsStoresAndKeepsCredentialOutOfOutput() async throws {
        let store = try InMemoryDatabaseSecretStore()
        let sender = CLIDatabaseScriptedSender { request in
            switch request {
            case .connectionTest(let testRequest):
                let identity = DatabaseProductIdentity(
                    product: .postgresql,
                    version: DatabaseVersion(string: "17.4"),
                    topology: DatabaseTopology(kind: .standalone))
                let report = DatabaseCapabilityReport(
                    productIdentity: identity,
                    capabilities: [],
                    discoveredAt: Date(timeIntervalSince1970: 2_000))
                return .connectionTest(
                    .success(
                        DatabaseConnectionTestResult(
                            connection: testRequest.connection.identity,
                            productIdentity: identity,
                            capabilities: report,
                            latencyMilliseconds: 12,
                            testedAt: Date(timeIntervalSince1970: 2_000)),
                        metadata: Self.completeMetadata))
            case .connectionSave(let saveRequest):
                return .connectionSave(
                    .success(
                        DatabaseConnectionSaveResult(connection: saveRequest.connection),
                        metadata: Self.completeMetadata))
            default:
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
        }

        try await CLIProbe.inWorld { _ in
            DatabaseCLIEnvironment.makeSender = { sender }
            DatabaseCLIEnvironment.makeSecretStore = { store }
            DatabaseCLIEnvironment.readPassword = { "TOP_SECRET_DATABASE_PASSWORD" }
            let result = await CLIProbe.capture([
                "database", "connections", "add", "TUF PostgreSQL",
                "--product", "postgresql",
                "--host", "127.0.0.1",
                "--port", "15432",
                "--username", "edith",
                "--database", "million_rows",
                "--password-stdin",
                "--json",
            ])

            #expect(result.code == ExitCodes.success)
            #expect(result.stderr.isEmpty)
            #expect(!result.stdout.contains("TOP_SECRET_DATABASE_PASSWORD"))
            #expect(!result.stdout.contains("passwordReference"))
            let output = try #require(result.object)
            #expect(output["testedProduct"] as? String == "postgresql")
            #expect(output["latencyMilliseconds"] as? Int == 12)

            let requests = await sender.recordedRequests()
            #expect(requests.count == 2)
            let tested = try #require(requests[0].connectionTestRequest?.connection)
            let saved = try #require(requests[1].connectionSaveRequest?.connection)
            #expect(tested == saved)
            #expect(tested.displayName == "TUF PostgreSQL")
            #expect(tested.environment.protection == .confirmationRequired)
            #expect(tested.readOnlyPolicy == .required)
            let reference = try #require(tested.authentication.secretReferences.first)
            #expect(try await store.read(reference) == Data("TOP_SECRET_DATABASE_PASSWORD".utf8))
        }
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

    private static func operation() throws -> DatabaseOperationRecordSummary {
        let connection = try connection()
        return DatabaseOperationRecordSummary(
            id: DatabaseOperationID(
                rawValue: UUID(uuidString: "0909B692-E58E-49E2-A707-7148943B3688")!),
            kind: DatabaseOperationKind(rawValue: "database.query"),
            state: .running,
            connection: connection.identity,
            target: DatabaseTargetIdentifier(
                connectionID: connection.id,
                object: DatabaseObjectIdentifier(kind: .table, path: ["public", "orders"])),
            startedAt: Date(timeIntervalSince1970: 7_000),
            deadline: Date(timeIntervalSince1970: 7_030),
            progress: .determinate(completed: 50, total: 100, unit: .records),
            cancellationSupport: .serverSide,
            retryClassification: .safeIdempotent,
            pageCount: 1,
            recordCount: 50,
            byteCount: 4_096)
    }

    private static func savedQuery() -> DatabaseSavedQuery {
        DatabaseSavedQuery(
            id: DatabaseSavedQueryID(rawValue: queryUUID),
            connectionID: DatabaseConnectionID(rawValue: connectionUUID),
            name: "Recent orders",
            language: .sql,
            text: "select id from public.orders",
            tags: ["reporting"],
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 5_000),
            updatedAt: Date(timeIntervalSince1970: 6_000))
    }

    private static func mutation() -> DatabaseDestructiveRequest {
        let target = DatabaseTargetIdentifier(
            connectionID: DatabaseConnectionID(rawValue: connectionUUID),
            object: DatabaseObjectIdentifier(kind: .table, path: ["public", "orders"]),
            record: DatabaseRecordIdentity(
                kind: .primaryKey,
                components: [
                    DatabaseIdentityComponent(name: "id", value: .signedInteger(42))
                ]))
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .postgresql,
                statement: "UPDATE public.orders SET note = $1 WHERE id = $2 RETURNING 1",
                parameters: [
                    DatabaseMutationParameter(name: "note", value: .string("verified")),
                    DatabaseMutationParameter(name: "id", value: .signedInteger(42)),
                ]))
    }

    private static func mutationPreview() throws -> DatabaseDestructivePreview {
        let connection = try connection()
        let effect = DatabaseDestructiveEffect(
            action: .update,
            connection: connection.identity,
            context: DatabaseMutationContext(
                kind: .database,
                value: "orders",
                schema: "public"),
            target: mutation().target,
            selectedRecords: [],
            predicate: nil,
            scope: .singleRecord,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                description: "one order row"),
            transactionBehavior: .transactional,
            rollbackAvailability: .available,
            executionMode: .synchronous,
            executionDigest: "execution-digest",
            displayDigest: "display-digest")
        return DatabaseDestructivePreview(
            effect: effect,
            request: DatabaseMutationPreview(
                product: .postgresql,
                kind: .sql,
                command: "UPDATE public.orders SET note = $1 WHERE id = $2 RETURNING 1",
                parameters: [],
                body: nil),
            warnings: [],
            requiredConfirmation: DatabaseRequiredConfirmation(
                strength: .connectionAndTarget,
                text: "Primary orders / public.orders"),
            issuedAt: Date(timeIntervalSince1970: 7_000),
            expiresAt: Date(timeIntervalSince1970: 7_120),
            token: DatabaseConfirmationToken(rawValue: "short-lived-token"))
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func page(note: String = "ready") -> DatabasePage<DatabaseRecord> {
        DatabasePage(
            records: [
                DatabaseRecord(
                    identity: DatabaseRecordIdentity(
                        kind: .primaryKey,
                        components: [
                            DatabaseIdentityComponent(name: "id", value: .signedInteger(42))
                        ]),
                    fields: [
                        DatabaseObjectField(name: "id", value: .signedInteger(42)),
                        DatabaseObjectField(name: "note", value: .string(note)),
                    ])
            ],
            fields: [
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("id"),
                    displayName: "id",
                    typeName: "int8",
                    isNullable: false,
                    isSortable: true,
                    isFilterable: true),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("note"),
                    displayName: "note",
                    typeName: "text",
                    isNullable: false,
                    isSortable: true,
                    isFilterable: true),
            ],
            nextContinuation: DatabaseContinuationToken(rawValue: "next-page"),
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: 12,
                    serverDurationMilliseconds: 8),
                bytesReceived: 128))
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
