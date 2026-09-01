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
