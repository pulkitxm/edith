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

    @Test("SQLite discovers tables and views from its main schema")
    func sqliteInitialDiscovery() async throws {
        let sender = DatabaseObjectExplorerScriptedSender(responses: [
            Self.response(records: [
                Self.relation("customers", kind: .table),
                Self.relation("active_customers", kind: .view),
            ])
        ])
        let model = DatabaseObjectExplorerModel(sender: sender)
        let connection = try Self.connection(product: .sqlite)

        model.load(connection)
        await Self.waitUntil {
            model.groups.first(where: { $0.title == "main" })?.state == .loaded
        }

        let requests = await sender.recordedRequests().compactMap(\.browseRequest)
        #expect(requests.count == 1)
        #expect(
            requests[0].target.object == DatabaseObjectIdentifier(kind: .schema, path: ["main"]))
        let objects = try #require(model.groups.first?.objects)
        #expect(objects.map(\.title) == ["customers", "active_customers"])
        #expect(objects.map(\.identifier.kind) == [.table, .view])
        #expect(model.selectedObject == objects.first?.identifier)
    }

    @Test("MongoDB discovers collections from its selected database")
    func mongoDBInitialDiscovery() async throws {
        let sender = DatabaseObjectExplorerScriptedSender(responses: [
            Self.response(records: [Self.relation("events", kind: .collection)]),
            Self.response(records: [Self.relation("events", kind: .collection)]),
        ])
        let model = DatabaseObjectExplorerModel(sender: sender)
        let connection = try Self.connection(product: .mongoDB)

        model.load(connection)
        await Self.waitUntil {
            model.groups.first(where: { $0.title == "app" })?.state == .loaded
        }

        let requests = await sender.recordedRequests().compactMap(\.browseRequest)
        #expect(requests.count == 1)
        #expect(
            requests[0].target.object == DatabaseObjectIdentifier(kind: .database, path: ["app"]))
        let object = try #require(model.groups.first?.objects.first)
        #expect(object.identifier.kind == .collection)
        #expect(object.identifier.path == ["app", "events"])
        #expect(model.selectedObject == object.identifier)

        model.load(connection)
        #expect(await sender.recordedRequests().count == 1)

        model.load(connection, force: true)
        for _ in 0..<10_000 {
            if await sender.recordedRequests().count == 2 { break }
            await Task.yield()
        }
        #expect(await sender.recordedRequests().count == 2)
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

    @Test("Elasticsearch discovers indices, aliases, and data streams")
    func elasticsearchDiscovery() async throws {
        let sender = DatabaseObjectExplorerScriptedSender(responses: [
            Self.response(records: [
                Self.relation("products", kind: .index),
                Self.relation("products-current", kind: .alias),
                Self.relation("logs", kind: .dataStream),
            ])
        ])
        let model = DatabaseObjectExplorerModel(sender: sender)
        let connection = try Self.connection(product: .elasticsearch)

        model.load(connection)
        await Self.waitUntil { model.groups.first?.state == .loaded }

        let request = try #require(await sender.recordedRequests().first?.browseRequest)
        #expect(
            request.target.object
                == DatabaseObjectIdentifier(kind: .server, path: ["indices"]))
        #expect(model.groups.first?.title == "Search objects")
        #expect(
            model.groups.first?.objects.map(\.identifier.path) == [
                ["products"], ["products-current"], ["logs"],
            ])
        #expect(
            model.groups.first?.objects.map(\.identifier.kind) == [.index, .alias, .dataStream])
    }

    @Test("OpenSearch discovers indices, aliases, and data streams")
    func openSearchDiscovery() async throws {
        let sender = DatabaseObjectExplorerScriptedSender(responses: [
            Self.response(records: [
                Self.relation("products", kind: .index),
                Self.relation("products-current", kind: .alias),
                Self.relation("logs", kind: .dataStream),
            ])
        ])
        let model = DatabaseObjectExplorerModel(sender: sender)
        let connection = try Self.connection(product: .openSearch)

        model.load(connection)
        await Self.waitUntil { model.groups.first?.state == .loaded }

        let request = try #require(await sender.recordedRequests().first?.browseRequest)
        #expect(
            request.target.object
                == DatabaseObjectIdentifier(kind: .server, path: ["indices"]))
        #expect(model.groups.first?.title == "Search objects")
        #expect(
            model.groups.first?.objects.map(\.identifier.path) == [
                ["products"], ["products-current"], ["logs"],
            ])
        #expect(
            model.groups.first?.objects.map(\.identifier.kind) == [.index, .alias, .dataStream])
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
