import EdithDatabase
import MCP
import Testing

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
