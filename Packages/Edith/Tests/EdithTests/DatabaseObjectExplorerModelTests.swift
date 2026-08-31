import Foundation
import Testing

@testable import Edith
@testable import EdithDatabase

@MainActor
@Suite("Database object explorer")
struct DatabaseObjectExplorerModelTests {
    @Test("PostgreSQL discovers schemas and loads only the preferred schema")
    func postgreSQLInitialDiscovery() async throws {
        let sender = DatabaseObjectExplorerScriptedSender(responses: [
            Self.response(records: [Self.schema("analytics"), Self.schema("public")]),
            Self.response(records: [Self.relation("customers", kind: .table)]),
        ])
        let model = DatabaseObjectExplorerModel(sender: sender)
        let connection = try Self.connection(product: .postgresql)

        model.load(connection)
        await Self.waitUntil {
            model.groups.first(where: { $0.title == "public" })?.state == .loaded
        }

        let requests = await sender.recordedRequests().compactMap(\.browseRequest)
        #expect(requests.count == 2)
        #expect(
            requests[0].target.object
                == DatabaseObjectIdentifier(kind: .database, path: ["app"]))
        #expect(
            requests[1].target.object == DatabaseObjectIdentifier(kind: .schema, path: ["public"]))
        #expect(requests.allSatisfy { $0.page.pageSize.value == 100 })
        #expect(model.groups.first(where: { $0.title == "analytics" })?.state == .idle)
        let object = try #require(
            model.groups.first(where: { $0.title == "public" })?.objects.first)
        #expect(
            object.identifier
                == DatabaseObjectIdentifier(kind: .table, path: ["public", "customers"]))
        #expect(object.estimatedRows == 42)
        #expect(object.columnCount == 7)
        #expect(model.selectedObject == object.identifier)
    }

    @Test("PostgreSQL expands another schema lazily and filters objects")
    func postgreSQLLazyGroup() async throws {
        let sender = DatabaseObjectExplorerScriptedSender(responses: [
            Self.response(records: [Self.schema("analytics"), Self.schema("public")]),
            Self.response(records: [Self.relation("customers", kind: .table)]),
            Self.response(records: [Self.relation("daily_sales", kind: .materializedView)]),
        ])
        let model = DatabaseObjectExplorerModel(sender: sender)
        let connection = try Self.connection(product: .postgresql)
        model.load(connection)
        await Self.waitUntil {
            model.groups.first(where: { $0.title == "public" })?.state == .loaded
        }

        let analytics = try #require(
            model.groups.first(where: { $0.title == "analytics" })?.identifier)
        model.loadGroup(analytics, connection: connection)
        await Self.waitUntil {
            model.groups.first(where: { $0.title == "analytics" })?.state == .loaded
        }

        let requests = await sender.recordedRequests().compactMap(\.browseRequest)
        #expect(requests.count == 3)
        #expect(requests[2].target.object == analytics)
        model.searchText = "daily"
        #expect(model.filteredGroups.map(\.title) == ["analytics"])
        #expect(model.filteredGroups.first?.objects.map(\.title) == ["daily_sales"])
        #expect(model.filteredGroups.first?.objects.first?.identifier.kind == .materializedView)
    }

    @Test("Redis selects its logical keyspace without discovery")
    func redisKeyspace() async throws {
        let sender = DatabaseObjectExplorerScriptedSender(responses: [])
        let model = DatabaseObjectExplorerModel(sender: sender)
        let connection = try Self.connection(product: .redis, logicalDatabase: "4")

        model.load(connection)

        let expected = DatabaseObjectIdentifier(kind: .keyspace, path: ["4"])
        #expect(model.state == .loaded)
        #expect(model.selectedObject == expected)
        #expect(model.groups.first?.objects.first?.identifier == expected)
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test("Discovery surfaces broker failures")
    func discoveryFailure() async throws {
        let message = "The selected object kind is not supported for discovery."
        let completeness = DatabaseResultCompleteness(state: .complete)
        let sender = DatabaseObjectExplorerScriptedSender(responses: [
            .browse(
                .failure(
                    DatabaseErrorEnvelope(category: .unsupported, message: message),
                    metadata: DatabaseResultMetadata(completeness: completeness)))
        ])
        let model = DatabaseObjectExplorerModel(sender: sender)

        model.load(try Self.connection(product: .postgresql))
        await Self.waitUntil { model.state == .failed(message) }

        #expect(model.state == .failed(message))
    }

    private static func connection(
        product: DatabaseProduct,
        logicalDatabase: String? = nil
    ) throws -> DatabaseConnectionSummary {
        DatabaseConnectionSummary(
            definition: DatabaseConnectionDefinition(
                id: DatabaseConnectionID(
                    rawValue: UUID(uuidString: "DE3E67A6-F561-47C8-9639-E76DB89EF179")!),
                displayName: "Explorer",
                productHint: product,
                location: .network([
                    DatabaseNetworkEndpoint(host: "db.internal", port: try DatabasePort(5_432))
                ]),
                namespaces: DatabaseNamespaceDefaults(
                    schema: "public",
                    database: "app",
                    logicalDatabase: logicalDatabase),
                authentication: DatabaseAuthentication(kind: .none),
                tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
                limits: DatabaseConnectionLimits(
                    connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                    operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                    poolSize: try DatabasePoolSize(4)),
                environment: DatabaseEnvironmentMetadata(
                    kind: .development,
                    label: "development",
                    protection: .standard),
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_000)))
    }

    private static func schema(_ name: String) -> DatabaseRecord {
        DatabaseRecord(fields: [
            DatabaseObjectField(name: "name", value: .string(name)),
            DatabaseObjectField(name: "canUse", value: .boolean(true)),
            DatabaseObjectField(name: "canCreate", value: .boolean(false)),
        ])
    }

    private static func relation(
        _ name: String,
        kind: DatabaseObjectKind
    ) -> DatabaseRecord {
        DatabaseRecord(fields: [
            DatabaseObjectField(name: "name", value: .string(name)),
            DatabaseObjectField(name: "kind", value: .string(kind.rawValue)),
            DatabaseObjectField(name: "estimatedRows", value: .signedInteger(42)),
            DatabaseObjectField(name: "columnCount", value: .signedInteger(7)),
        ])
    }

    private static func response(
        records: [DatabaseRecord]
    ) -> DatabaseBrokerCommandResponse {
        let completeness = DatabaseResultCompleteness(state: .complete)
        return .browse(
            .success(
                DatabaseBrowseResult(
                    page: DatabasePage(
                        records: records,
                        metadata: DatabasePageMetadata(
                            completeness: completeness,
                            count: DatabaseCountMetadata(
                                value: UInt64(records.count),
                                accuracy: .exact)))),
                metadata: DatabaseResultMetadata(completeness: completeness)))
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("The object explorer did not reach the expected state.")
    }
}

private actor DatabaseObjectExplorerScriptedSender: DatabaseBrokerCommandSending {
    private var responses: [DatabaseBrokerCommandResponse]
    private var requests: [DatabaseBrokerCommandRequest] = []

    init(responses: [DatabaseBrokerCommandResponse]) {
        self.responses = responses
    }

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw DatabaseBrokerCommandClientError.invalidRequest
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] {
        requests
    }
}

private extension DatabaseBrokerCommandRequest {
    var browseRequest: DatabaseBrowseRequest? {
        guard case .browse(let request) = self else { return nil }
        return request
    }
}
