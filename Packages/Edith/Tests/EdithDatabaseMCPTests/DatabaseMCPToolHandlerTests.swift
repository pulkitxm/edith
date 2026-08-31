import MCP
import Testing

@testable import EdithDatabase
@testable import EdithDatabaseMCP

@Suite struct DatabaseMCPToolHandlerTests {
    @Test func listsSafeConnectionProjectionsThroughTheBroker() async throws {
        let connection = try DatabaseMCPFixtures.connection()
        let sender = DatabaseMCPScriptedSender([
            .success(
                .connectionList(
                    .success(
                        DatabaseConnectionListResult(connections: [connection]),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_connections",
                arguments: ["action": "list", "search": "orders"]))

        #expect(result.isError == false)
        let root = result.structuredContent?.objectValue
        #expect(root?["status"]?.stringValue == "succeeded")
        let data = root?["data"]?.objectValue
        let connections = data?["connections"]?.arrayValue
        #expect(connections?.count == 1)
        let projected = connections?.first?.objectValue
        #expect(projected?["id"]?.stringValue == connection.id.rawValue.uuidString.lowercased())
        #expect(projected?["display_name"]?.stringValue == "Primary orders")
        #expect(projected?["product"]?.stringValue == "postgresql")
        #expect(projected?["read_only_policy"]?.stringValue == "preferred")
        #expect(projected?["environment"]?.objectValue?["kind"]?.stringValue == "production")

        let text = Self.text(result)
        #expect(!text.contains("secret-user"))
        #expect(!text.contains("sensitive.internal.example"))
        #expect(!text.contains("authentication"))

        let requests = await sender.recordedRequests()
        #expect(requests.count == 1)
        guard case let .connectionList(request) = requests.first else {
            Issue.record("Expected a connection-list request.")
            return
        }
        #expect(request.search.text == "orders")
        #expect(request.search.limit == 100)
    }

    @Test func getsOneConnectionAndReturnsAnExplicitNullWhenMissing() async {
        let sender = DatabaseMCPScriptedSender([
            .success(
                .connectionGet(
                    .success(
                        DatabaseConnectionGetResult(connection: nil),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_connections",
                arguments: [
                    "action": "get",
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                ]))

        #expect(result.isError == false)
        let data = result.structuredContent?.objectValue?["data"]?.objectValue
        #expect(data?["action"]?.stringValue == "get")
        #expect(data?["connection"]?.isNull == true)
        let requests = await sender.recordedRequests()
        guard case let .connectionGet(request) = requests.first else {
            Issue.record("Expected a connection-get request.")
            return
        }
        #expect(request.connectionID == DatabaseMCPFixtures.connectionID)
    }

    @Test func capabilitiesPreserveTypedStatusMetadataAndExactRequestContext() async throws {
        let operation = DatabaseOperationRecordSummary(
            id: DatabaseMCPFixtures.operationID,
            kind: "database.capabilities",
            state: .succeeded,
            connection: try DatabaseMCPFixtures.connection().identity,
            startedAt: DatabaseMCPFixtures.now,
            finishedAt: DatabaseMCPFixtures.now,
            cancellationSupport: .cooperative,
            retryClassification: .safeIdempotent)
        let metadata = DatabaseResultMetadata(
            operation: operation,
            completeness: DatabaseResultCompleteness(state: .complete),
            warnings: [
                DatabaseWarning(
                    code: "cached",
                    message: "Capability details were refreshed.",
                    severity: .information)
            ])
        let sender = DatabaseMCPScriptedSender([
            .success(
                .capabilities(
                    .success(
                        DatabaseCapabilitiesResult(
                            report: DatabaseMCPFixtures.capabilityReport(),
                            source: .discovered),
                        metadata: metadata)))
        ])
        let handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: { DatabaseMCPFixtures.operationID })

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_capabilities",
                arguments: [
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "refresh": true,
                ]))

        #expect(result.isError == false)
        let root = result.structuredContent?.objectValue
        #expect(root?["status"]?.stringValue == "succeeded")
        let data = root?["data"]?.objectValue
        #expect(data?["source"]?.stringValue == "discovered")
        let report = data?["report"]?.objectValue
        #expect(report?["product"]?.objectValue?["product"]?.stringValue == "postgresql")
        #expect(report?["capabilities"]?.arrayValue?.count == 2)
        let outputMetadata = root?["metadata"]?.objectValue
        #expect(
            outputMetadata?["operation"]?.objectValue?["id"]?.stringValue
                == DatabaseMCPFixtures.operationID.rawValue.uuidString.lowercased())
        #expect(outputMetadata?["warnings"]?.arrayValue?.count == 1)

        let requests = await sender.recordedRequests()
        guard case let .capabilities(request) = requests.first else {
            Issue.record("Expected a capabilities request.")
            return
        }
        #expect(request.connectionID == DatabaseMCPFixtures.connectionID)
        #expect(request.resolution == .refresh)
        #expect(request.operation.operationID == DatabaseMCPFixtures.operationID)
    }

    @Test func browseUsesExplicitTargetBoundsAndOpaqueContinuation() async throws {
        let sender = DatabaseMCPScriptedSender([
            .success(
                .browse(
                    .success(
                        DatabaseBrowseResult(page: DatabaseMCPFixtures.page()),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: { DatabaseMCPFixtures.operationID })

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_browse",
                arguments: [
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "object_kind": "table",
                    "object_path": .array(["public", "orders"]),
                    "page_size": 25,
                    "continuation": "previous-page",
                    "timeout_ms": 5_000,
                ]))

        #expect(result.isError == false)
        let page = result.structuredContent?.objectValue?["data"]?.objectValue?["page"]?
            .objectValue
        #expect(page?["records"]?.arrayValue?.count == 1)
        #expect(page?["fields"]?.arrayValue?.count == 2)
        #expect(page?["next_continuation"]?.stringValue == "next-page")
        #expect(
            page?["metadata"]?.objectValue?["completeness"]?.objectValue?["state"]?
                .stringValue == "partial")

        let requests = await sender.recordedRequests()
        guard case let .browse(request) = requests.first else {
            Issue.record("Expected a browse request.")
            return
        }
        #expect(request.target.connectionID == DatabaseMCPFixtures.connectionID)
        #expect(request.target.object?.kind == .table)
        #expect(request.target.object?.path == ["public", "orders"])
        #expect(request.page.pageSize.value == 25)
        #expect(request.page.continuation?.rawValue == "previous-page")
        #expect(request.operation.operationID == DatabaseMCPFixtures.operationID)
        #expect(request.operation.deadline != nil)
    }

    @Test func queryPreservesLanguageAndBoundsLargeValues() async throws {
        let sender = DatabaseMCPScriptedSender([
            .success(
                .query(
                    .success(
                        DatabaseQueryResult(
                            page: DatabaseMCPFixtures.page(
                                note: String(repeating: "x", count: 3_000))),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: { DatabaseMCPFixtures.operationID })

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_query",
                arguments: [
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "language": "sql",
                    "command": "select * from public.orders",
                    "page_size": 10,
                ]))

        #expect(result.isError == false)
        let records = result.structuredContent?.objectValue?["data"]?.objectValue?["page"]?
            .objectValue?["records"]?.arrayValue
        let fields = records?.first?.objectValue?["fields"]?.arrayValue
        let note = fields?.first(where: {
            $0.objectValue?["name"]?.stringValue == "note"
        })?.objectValue?["value"]?.objectValue
        #expect(note?["truncated"]?.boolValue == true)
        #expect(note?["characters"]?.intValue == 3_000)

        let requests = await sender.recordedRequests()
        guard case let .query(request) = requests.first else {
            Issue.record("Expected a query request.")
            return
        }
        #expect(request.target.connectionID == DatabaseMCPFixtures.connectionID)
        #expect(request.target.object == nil)
        #expect(request.language == .sql)
        #expect(request.command == "select * from public.orders")
        #expect(request.page.pageSize.value == 10)
        #expect(request.operation.operationID == DatabaseMCPFixtures.operationID)
    }

    @Test func clickHouseQueryUsesTheSharedTypedCommand() async throws {
        let sender = DatabaseMCPScriptedSender([
            .success(
                .query(
                    .success(
                        DatabaseQueryResult(page: DatabaseMCPFixtures.page()),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: { DatabaseMCPFixtures.operationID })

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_query",
                arguments: [
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "language": "clickHouseSQL",
                    "command": "SELECT category, count() FROM events GROUP BY category",
                    "page_size": 100,
                ]))

        #expect(result.isError == false)
        let requests = await sender.recordedRequests()
        guard case let .query(request) = requests.first else {
            Issue.record("Expected a ClickHouse query request.")
            return
        }
        #expect(request.language == .clickHouseSQL)
        #expect(request.command == "SELECT category, count() FROM events GROUP BY category")
        #expect(request.page.pageSize.value == 100)
        #expect(request.operation.operationID == DatabaseMCPFixtures.operationID)
    }

    @Test func rejectsUnsafePageAndQueryInputsBeforeCallingTheBroker() async {
        let sender = DatabaseMCPScriptedSender([])
        let handler = DatabaseMCPToolHandler(sender: sender)
        let connectionID = DatabaseMCPFixtures.connectionID.rawValue.uuidString

        let missingObject = await handler.callTool(
            CallTool.Parameters(
                name: "database_browse",
                arguments: [
                    "connection_id": .string(connectionID),
                    "object_kind": "table",
                ]))
        let oversizedPage = await handler.callTool(
            CallTool.Parameters(
                name: "database_browse",
                arguments: [
                    "connection_id": .string(connectionID),
                    "object_kind": "table",
                    "object_path": .array(["orders"]),
                    "page_size": 501,
                ]))
        let unsupportedLanguage = await handler.callTool(
            CallTool.Parameters(
                name: "database_query",
                arguments: [
                    "connection_id": .string(connectionID),
                    "language": "shell",
                    "command": "select 1",
                ]))

        #expect(missingObject.isError == true)
        #expect(oversizedPage.isError == true)
        #expect(unsupportedLanguage.isError == true)
        #expect(Self.category(missingObject) == "invalidRequest")
        #expect(Self.category(oversizedPage) == "invalidRequest")
        #expect(Self.category(unsupportedLanguage) == "invalidRequest")
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test func keyMutationRequiresPreviewBoundConfirmation() async throws {
        let target = DatabaseTargetIdentifier(
            connectionID: DatabaseMCPFixtures.connectionID,
            object: DatabaseObjectIdentifier(kind: .keyspace, path: ["2"]),
            record: DatabaseRecordIdentity(
                kind: .key,
                components: [
                    DatabaseIdentityComponent(name: "key", value: .string("session:1"))
                ]))
        let mutation = try DatabaseKeyspaceMutationRequests.updateString(
            target: target,
            product: .valkey,
            value: .string("ready"),
            ttlMilliseconds: nil,
            preservesExistingTTL: false)
        let effect = DatabaseDestructiveEffect(
            action: .update,
            connection: try DatabaseMCPFixtures.connection().identity,
            context: DatabaseMutationContext(kind: .logicalDatabase, value: "2"),
            target: target,
            selectedRecords: [],
            predicate: nil,
            scope: .singleRecord,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                description: "Update one string key"),
            transactionBehavior: .nontransactional,
            rollbackAvailability: .unavailable,
            executionMode: .synchronous,
            executionDigest: "execution-digest",
            displayDigest: "display-digest")
        let preview = DatabaseDestructivePreview(
            effect: effect,
            request: DatabaseMutationPreview(
                product: .valkey,
                kind: .keyspace,
                command: "SET",
                parameters: mutation.payload.parameters.map {
                    DatabaseMutationParameterPreview(name: $0.name, valueKind: .string)
                },
                body: nil),
            warnings: [
                DatabaseWarning(
                    code: "redis.mutation.no_rollback",
                    message: "This change cannot be rolled back.",
                    severity: .caution)
            ],
            requiredConfirmation: DatabaseRequiredConfirmation(
                strength: .target,
                text: "Primary orders / 2"),
            issuedAt: DatabaseMCPFixtures.now,
            expiresAt: DatabaseMCPFixtures.now.addingTimeInterval(60),
            token: DatabaseConfirmationToken(rawValue: "preview-token"))
        let sender = DatabaseMCPScriptedSender([
            .success(
                .mutationPreview(
                    .success(
                        DatabaseMutationPreviewResult(preview: preview),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
            .success(
                .mutationApply(
                    .success(
                        DatabaseMutationApplyResult(
                            disposition: .completed,
                            effect: .applied,
                            affectedRecords: DatabaseCountMetadata(value: 1, accuracy: .exact)),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
        ])
        let handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: { DatabaseMCPFixtures.operationID })
        let base: [String: Value] = [
            "connection_id": .string(DatabaseMCPFixtures.connectionID.rawValue.uuidString),
            "product": "valkey",
            "action": "update",
            "logical_database": "2",
            "key": "session:1",
            "value": "ready",
            "ttl_ms": -1,
        ]
        var previewArguments = base
        previewArguments["mode"] = "preview"
        let previewResult = await handler.callTool(
            CallTool.Parameters(
                name: "database_key_mutation",
                arguments: previewArguments))
        #expect(previewResult.isError == false)
        let previewData = previewResult.structuredContent?.objectValue?["data"]?.objectValue
        #expect(previewData?["confirmation_token"]?.stringValue == "preview-token")
        #expect(previewData?["rollback"]?.stringValue == "unavailable")

        var applyArguments = base
        applyArguments["mode"] = "apply"
        applyArguments["confirmation_token"] = "preview-token"
        applyArguments["confirmation_text"] = "Primary orders / 2"
        let applyResult = await handler.callTool(
            CallTool.Parameters(
                name: "database_key_mutation",
                arguments: applyArguments))
        #expect(applyResult.isError == false)
        let applyData = applyResult.structuredContent?.objectValue?["data"]?.objectValue
        #expect(applyData?["effect"]?.stringValue == "applied")
        #expect(applyData?["affected_records"]?.objectValue?["value"]?.intValue == 1)

        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.first?.mutationPreviewRequest?.mutation == mutation)
        #expect(requests.last?.mutationApplyRequest?.mutation == mutation)
        #expect(requests.last?.mutationApplyRequest?.token.rawValue == "preview-token")
    }

    @Test func documentMutationUsesTheSamePreviewBoundContract() async throws {
        let target = DatabaseTargetIdentifier(
            connectionID: DatabaseMCPFixtures.connectionID,
            object: DatabaseObjectIdentifier(kind: .collection, path: ["app", "people"]),
            record: DatabaseRecordIdentity(
                kind: .documentID,
                components: [
                    DatabaseIdentityComponent(
                        name: "_id",
                        value: .productSpecific(
                            DatabaseProductValue(
                                product: .mongoDB,
                                typeName: "objectId",
                                textRepresentation: "507f1f77bcf86cd799439011")))
                ]))
        let mutation = try DatabaseDocumentMutationRequests.mongoDBUpdate(
            target: target,
            values: [
                DatabaseObjectField(name: "active", value: .boolean(true)),
                DatabaseObjectField(name: "name", value: .string("Ada")),
                DatabaseObjectField(
                    name: "tags",
                    value: .array([.string("math"), .string("code")])),
            ])
        let effect = DatabaseDestructiveEffect(
            action: .update,
            connection: try DatabaseMCPFixtures.connection().identity,
            context: DatabaseMutationContext(kind: .database, value: "app"),
            target: target,
            selectedRecords: [],
            predicate: nil,
            scope: .singleRecord,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                description: "Update one identified document"),
            transactionBehavior: .nontransactional,
            rollbackAvailability: .unavailable,
            executionMode: .synchronous,
            executionDigest: "document-execution-digest",
            displayDigest: "document-display-digest")
        let preview = DatabaseDestructivePreview(
            effect: effect,
            request: DatabaseMutationPreview(
                product: .mongoDB,
                kind: .document,
                command: "updateOne",
                parameters: [],
                body: mutation.payload.body),
            warnings: [],
            requiredConfirmation: DatabaseRequiredConfirmation(
                strength: .target,
                text: "Primary orders / app / people"),
            issuedAt: DatabaseMCPFixtures.now,
            expiresAt: DatabaseMCPFixtures.now.addingTimeInterval(60),
            token: DatabaseConfirmationToken(rawValue: "document-preview-token"))
        let sender = DatabaseMCPScriptedSender([
            .success(
                .mutationPreview(
                    .success(
                        DatabaseMutationPreviewResult(preview: preview),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
            .success(
                .mutationApply(
                    .success(
                        DatabaseMutationApplyResult(
                            disposition: .completed,
                            effect: .applied,
                            affectedRecords: DatabaseCountMetadata(value: 1, accuracy: .exact)),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
        ])
        let handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: { DatabaseMCPFixtures.operationID })
        let base: [String: Value] = [
            "connection_id": .string(DatabaseMCPFixtures.connectionID.rawValue.uuidString),
            "product": "mongodb",
            "action": "update",
            "database": "app",
            "collection": "people",
            "document_id": "507f1f77bcf86cd799439011",
            "document": .object([
                "active": true,
                "name": "Ada",
                "tags": .array(["math", "code"]),
            ]),
        ]
        var previewArguments = base
        previewArguments["mode"] = "preview"
        let previewResult = await handler.callTool(
            CallTool.Parameters(
                name: "database_document_mutation",
                arguments: previewArguments))
        #expect(previewResult.isError == false)
        #expect(
            previewResult.structuredContent?.objectValue?["data"]?.objectValue?[
                "confirmation_token"
            ]?.stringValue == "document-preview-token")

        var applyArguments = base
        applyArguments["mode"] = "apply"
        applyArguments["confirmation_token"] = "document-preview-token"
        applyArguments["confirmation_text"] = "Primary orders / app / people"
        let applyResult = await handler.callTool(
            CallTool.Parameters(
                name: "database_document_mutation",
                arguments: applyArguments))
        #expect(applyResult.isError == false)
        #expect(
            applyResult.structuredContent?.objectValue?["data"]?.objectValue?["effect"]?
                .stringValue == "applied")

        let requests = await sender.recordedRequests()
        #expect(requests.first?.mutationPreviewRequest?.mutation == mutation)
        #expect(requests.last?.mutationApplyRequest?.mutation == mutation)
        #expect(requests.last?.mutationApplyRequest?.token.rawValue == "document-preview-token")
    }

    @Test func elasticsearchDocumentMutationCarriesConcurrencyAndPlainJSON() async throws {
        let sender = DatabaseMCPScriptedSender([])
        let handler = DatabaseMCPToolHandler(sender: sender)
        _ = await handler.callTool(
            CallTool.Parameters(
                name: "database_document_mutation",
                arguments: [
                    "mode": "preview",
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "product": "elasticsearch",
                    "action": "update",
                    "index": "edith-documents-v1",
                    "document_id": "doc-1",
                    "sequence_number": 7,
                    "primary_term": 2,
                    "document": .object([
                        "event": .object(["$date": "literal"]),
                        "title": "updated",
                    ]),
                ]))

        let requests = await sender.recordedRequests()
        let mutation = try #require(requests.first?.mutationPreviewRequest?.mutation)
        #expect(mutation.target.object?.kind == .index)
        #expect(mutation.target.object?.path == ["edith-documents-v1"])
        #expect(mutation.target.record?.kind == .searchDocument)
        #expect(
            mutation.target.record?.concurrencyTokens.map(\.value) == [
                .signedInteger(7), .signedInteger(2),
            ])
        #expect(mutation.payload.product == .elasticsearch)
        #expect(mutation.payload.command == "replace")
        guard case .object(let fields) = mutation.payload.body else {
            Issue.record("expected an Elasticsearch document body")
            return
        }
        #expect(
            fields.first(where: { $0.name == "event" })?.value
                == .object([
                    DatabaseObjectField(name: "$date", value: .string("literal"))
                ]))
    }

    @Test func openSearchDocumentMutationCarriesConcurrencyAndPlainJSON() async throws {
        let sender = DatabaseMCPScriptedSender([])
        let handler = DatabaseMCPToolHandler(sender: sender)
        _ = await handler.callTool(
            CallTool.Parameters(
                name: "database_document_mutation",
                arguments: [
                    "mode": "preview",
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "product": "opensearch",
                    "action": "update",
                    "index": "edith-documents-v1",
                    "document_id": "doc-1",
                    "sequence_number": 7,
                    "primary_term": 2,
                    "document": .object([
                        "event": .object(["$date": "literal"]),
                        "title": "updated",
                    ]),
                ]))

        let requests = await sender.recordedRequests()
        let mutation = try #require(requests.first?.mutationPreviewRequest?.mutation)
        #expect(mutation.target.object?.kind == .index)
        #expect(mutation.target.record?.kind == .searchDocument)
        #expect(
            mutation.target.record?.concurrencyTokens.map(\.value) == [
                .signedInteger(7), .signedInteger(2),
            ])
        #expect(mutation.payload.product == .openSearch)
        #expect(mutation.payload.command == "replace")
        guard case .object(let fields) = mutation.payload.body else {
            Issue.record("expected an OpenSearch document body")
            return
        }
        #expect(
            fields.first(where: { $0.name == "event" })?.value
                == .object([
                    DatabaseObjectField(name: "$date", value: .string("literal"))
                ]))
    }

    @Test func operationListPreservesFiltersProgressAndTarget() async throws {
        let operation = try DatabaseMCPFixtures.operation()
        let sender = DatabaseMCPScriptedSender([
            .success(
                .operationList(
                    .success(
                        DatabaseOperationListResult(operations: [operation]),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_operations",
                arguments: [
                    "action": "list",
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "states": .array(["running", "cancelling"]),
                    "kinds": .array(["database.query"]),
                    "before": "2026-08-31T10:00:00Z",
                    "limit": 25,
                ]))

        #expect(result.isError == false)
        let operations = result.structuredContent?.objectValue?["data"]?.objectValue?[
            "operations"
        ]?.arrayValue
        let projected = operations?.first?.objectValue
        #expect(projected?["state"]?.stringValue == "running")
        #expect(projected?["progress"]?.objectValue?["completed"]?.intValue == 50)
        #expect(
            projected?["target"]?.objectValue?["object"]?.objectValue?["path"]?.arrayValue
                == ["public", "orders"])

        let requests = await sender.recordedRequests()
        guard case let .operationList(request) = requests.first else {
            Issue.record("Expected an operation-list request.")
            return
        }
        #expect(request.search.connectionID == DatabaseMCPFixtures.connectionID)
        #expect(request.search.states == [.running, .cancelling])
        #expect(request.search.kinds == [DatabaseOperationKind(rawValue: "database.query")])
        #expect(request.search.limit == 25)
        #expect(request.search.before != nil)
    }

    @Test func operationGetReturnsExplicitNullWhenMissing() async {
        let sender = DatabaseMCPScriptedSender([
            .success(
                .operationGet(
                    .success(
                        DatabaseOperationGetResult(operation: nil),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_operations",
                arguments: [
                    "action": "get",
                    "operation_id": .string(
                        DatabaseMCPFixtures.operationID.rawValue.uuidString),
                ]))

        #expect(result.isError == false)
        #expect(
            result.structuredContent?.objectValue?["data"]?.objectValue?["operation"]?.isNull
                == true)
        let requests = await sender.recordedRequests()
        #expect(requests.first?.operationGetRequest?.operationID == DatabaseMCPFixtures.operationID)
    }

    @Test func cancelOperationUsesSeparateTypedMutationTool() async throws {
        let operation = try DatabaseMCPFixtures.operation()
        let sender = DatabaseMCPScriptedSender([
            .success(
                .operationCancel(
                    .success(
                        DatabaseOperationCancelResult(
                            operationID: operation.id,
                            disposition: .accepted,
                            cancellationSupport: .serverSide,
                            operation: operation),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_cancel_operation",
                arguments: [
                    "operation_id": .string(operation.id.rawValue.uuidString)
                ]))

        #expect(result.isError == false)
        let data = result.structuredContent?.objectValue?["data"]?.objectValue
        #expect(data?["disposition"]?.stringValue == "accepted")
        #expect(data?["cancellation_support"]?.stringValue == "serverSide")
        let requests = await sender.recordedRequests()
        #expect(requests.first?.operationCancelRequest?.operationID == operation.id)
    }

    @Test func rejectsInvalidOperationInputsBeforeCallingTheBroker() async {
        let sender = DatabaseMCPScriptedSender([])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let invalidID = await handler.callTool(
            CallTool.Parameters(
                name: "database_cancel_operation",
                arguments: ["operation_id": "not-a-uuid"]))
        let invalidLimit = await handler.callTool(
            CallTool.Parameters(
                name: "database_operations",
                arguments: ["action": "list", "limit": 1_001]))
        let invalidState = await handler.callTool(
            CallTool.Parameters(
                name: "database_operations",
                arguments: ["action": "list", "states": .array(["unknown"])]))

        #expect(invalidID.isError == true)
        #expect(invalidLimit.isError == true)
        #expect(invalidState.isError == true)
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test func testsSavedConnectionWithoutExposingDefinitionSecrets() async throws {
        let connection = try DatabaseMCPFixtures.connection()
        let report = DatabaseMCPFixtures.capabilityReport()
        let sender = DatabaseMCPScriptedSender([
            .success(
                .connectionGet(
                    .success(
                        DatabaseConnectionGetResult(connection: connection),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
            .success(
                .connectionTest(
                    .success(
                        DatabaseConnectionTestResult(
                            connection: connection.identity,
                            productIdentity: report.productIdentity,
                            capabilities: report,
                            latencyMilliseconds: 80,
                            testedAt: DatabaseMCPFixtures.now),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
        ])
        let handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: { DatabaseMCPFixtures.operationID })

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_test_connection",
                arguments: [
                    "connection_id": .string(connection.id.rawValue.uuidString),
                    "timeout_ms": 10_000,
                ]))

        #expect(result.isError == false)
        let data = result.structuredContent?.objectValue?["data"]?.objectValue
        #expect(data?["latency_ms"]?.intValue == 80)
        #expect(data?["product"]?.stringValue == "postgresql")
        #expect(!Self.text(result).contains("secret-user"))
        #expect(!Self.text(result).contains("sensitive.internal.example"))

        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.first?.connectionGetRequest?.connectionID == connection.id)
        #expect(requests.last?.connectionTestRequest?.connection == connection)
        #expect(
            requests.last?.connectionTestRequest?.operation.operationID
                == DatabaseMCPFixtures.operationID)
    }

    @Test func managesExplicitConnectAndDisconnectSessions() async throws {
        let connection = try DatabaseMCPFixtures.connection()
        let report = DatabaseMCPFixtures.capabilityReport()
        let sender = DatabaseMCPScriptedSender([
            .success(
                .connect(
                    .success(
                        DatabaseConnectResult(
                            connection: connection.identity,
                            productIdentity: report.productIdentity,
                            capabilities: report,
                            connectedAt: DatabaseMCPFixtures.now),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
            .success(
                .disconnect(
                    .success(
                        DatabaseDisconnectResult(
                            connection: connection.identity,
                            disconnected: true,
                            disconnectedAt: DatabaseMCPFixtures.now),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
        ])
        let handler = DatabaseMCPToolHandler(
            sender: sender,
            makeOperationID: { DatabaseMCPFixtures.operationID })
        let connectionID = connection.id.rawValue.uuidString

        let connect = await handler.callTool(
            CallTool.Parameters(
                name: "database_session",
                arguments: [
                    "action": "connect",
                    "connection_id": .string(connectionID),
                ]))
        let disconnect = await handler.callTool(
            CallTool.Parameters(
                name: "database_session",
                arguments: [
                    "action": "disconnect",
                    "connection_id": .string(connectionID),
                ]))

        #expect(connect.isError == false)
        #expect(disconnect.isError == false)
        #expect(
            connect.structuredContent?.objectValue?["data"]?.objectValue?["product"]?
                .stringValue == "postgresql")
        #expect(
            disconnect.structuredContent?.objectValue?["data"]?.objectValue?["disconnected"]?
                .boolValue == true)
        let requests = await sender.recordedRequests()
        #expect(requests.first?.connectRequest?.connectionID == connection.id)
        #expect(requests.last?.disconnectRequest?.connectionID == connection.id)
    }

    @Test func rejectsInvalidSessionActionBeforeCallingTheBroker() async {
        let sender = DatabaseMCPScriptedSender([])
        let handler = DatabaseMCPToolHandler(sender: sender)
        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_session",
                arguments: [
                    "action": "restart",
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                ]))

        #expect(result.isError == true)
        #expect(Self.category(result) == "invalidRequest")
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test func rejectsInvalidAndUnknownArgumentsWithoutCallingTheBroker() async {
        let sender = DatabaseMCPScriptedSender([])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let invalidID = await handler.callTool(
            CallTool.Parameters(
                name: "database_connections",
                arguments: ["action": "get", "connection_id": "not-a-uuid"]))
        let unknownArgument = await handler.callTool(
            CallTool.Parameters(
                name: "database_capabilities",
                arguments: [
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "password": "must-not-be-accepted",
                ]))

        #expect(invalidID.isError == true)
        #expect(Self.category(invalidID) == "invalidRequest")
        #expect(unknownArgument.isError == true)
        #expect(Self.category(unknownArgument) == "invalidRequest")
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test func rejectsOversizedDocumentMutationBeforeCallingTheBroker() async {
        let sender = DatabaseMCPScriptedSender([])
        let handler = DatabaseMCPToolHandler(sender: sender)
        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_document_mutation",
                arguments: [
                    "mode": "preview",
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString),
                    "product": "mongodb",
                    "action": "insert",
                    "database": "app",
                    "collection": "people",
                    "document": .object([
                        "payload": .string(String(repeating: "x", count: 1_048_576))
                    ]),
                ]))

        #expect(result.isError == true)
        #expect(Self.category(result) == "invalidRequest")
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test func preservesCommandFailureAndPartialResultSemantics() async {
        let error = DatabaseErrorEnvelope(
            category: .permissionDenied,
            message: "Capability inspection is not permitted.",
            retry: DatabaseRetryGuidance(action: .none),
            partialResult: DatabaseResultCompleteness(
                state: .partial,
                reason: "Some grants were hidden."))
        let metadata = DatabaseResultMetadata(
            completeness: DatabaseResultCompleteness(state: .partial),
            partialFailures: [DatabasePartialFailure(error: error)])
        let sender = DatabaseMCPScriptedSender([
            .success(.capabilities(.failure(error, metadata: metadata)))
        ])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let result = await handler.callTool(
            CallTool.Parameters(
                name: "database_capabilities",
                arguments: [
                    "connection_id": .string(
                        DatabaseMCPFixtures.connectionID.rawValue.uuidString)
                ]))

        #expect(result.isError == true)
        #expect(Self.category(result) == "permissionDenied")
        let root = result.structuredContent?.objectValue
        #expect(
            root?["error"]?.objectValue?["partial_result"]?.objectValue?["state"]?.stringValue
                == "partial")
        #expect(root?["metadata"]?.objectValue?["partial_failures"]?.arrayValue?.count == 1)
    }

    @Test func reportsTransportAndResponseKindFailuresAsStructuredErrors() async {
        let sender = DatabaseMCPScriptedSender([
            .failure(.timedOut),
            .success(
                .connectionGet(
                    .success(
                        DatabaseConnectionGetResult(connection: nil),
                        metadata: DatabaseMCPFixtures.completeMetadata))),
        ])
        let handler = DatabaseMCPToolHandler(sender: sender)

        let timeout = await handler.callTool(
            CallTool.Parameters(
                name: "database_connections",
                arguments: ["action": "list"]))
        let mismatch = await handler.callTool(
            CallTool.Parameters(
                name: "database_connections",
                arguments: ["action": "list"]))

        #expect(timeout.isError == true)
        #expect(Self.category(timeout) == "timeout")
        #expect(mismatch.isError == true)
        #expect(Self.category(mismatch) == "decoding")
        #expect(Self.text(mismatch).contains("database.connection.list"))
        #expect(Self.text(mismatch).contains("database.connection.get"))
    }

    private static func category(_ result: CallTool.Result) -> String? {
        result.structuredContent?.objectValue?["error"]?.objectValue?["category"]?
            .stringValue
    }

    private static func text(_ result: CallTool.Result) -> String {
        guard case let .text(text, _, _)? = result.content.first else { return "" }
        return text
    }
}
