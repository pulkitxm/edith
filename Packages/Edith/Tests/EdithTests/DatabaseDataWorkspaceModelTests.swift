import Foundation
import Testing

@testable import Edith
@testable import EdithDatabase

@MainActor
@Suite("Database data workspace")
struct DatabaseDataWorkspaceModelTests {
    @Test("PostgreSQL browsing sends bounded target, filter, and sort controls")
    func postgreSQLBrowseRequest() async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)])
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.targetText = "analytics.orders"
        model.filterField = "customer_name"
        model.filterValue = "Ada"
        model.sortField = "created_at"
        model.sortDirection = .descending

        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        let request = try #require((await sender.recordedRequests()).first?.browseRequest)
        #expect(request.target.connectionID == connection.id)
        #expect(request.target.object?.kind == .table)
        #expect(request.target.object?.path == ["analytics", "orders"])
        #expect(request.page.pageSize.value == 100)
        #expect(
            request.page.filter
                == .predicate(
                    DatabaseFilterPredicate(
                        field: DatabaseFieldPath("customer_name"),
                        operation: .contains,
                        values: [.string("Ada")],
                        caseSensitivity: .insensitive)))
        #expect(
            request.page.sorts
                == [
                    DatabaseSort(
                        field: DatabaseFieldPath("created_at"),
                        direction: .descending)
                ])
        #expect(model.records == [Self.record(1)])
    }

    @Test("Continuation browsing appends records and forwards the token")
    func continuationBrowse() async throws {
        let token = DatabaseContinuationToken(rawValue: "next-page")
        let sender = DatabaseDataScriptedSender(
            responses: [
                Self.response(records: [Self.record(1)], nextContinuation: token),
                Self.response(records: [Self.record(2)]),
            ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.targetText = "public.customers"

        model.browse(connection)
        await Self.waitUntil { model.state == .loaded && model.hasNextPage }
        model.loadNextPage(connection)
        await Self.waitUntil { model.state == .loaded && model.records.count == 2 }

        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].browseRequest?.page.continuation == nil)
        #expect(requests[1].browseRequest?.page.continuation == token)
        #expect(model.records == [Self.record(1), Self.record(2)])
        #expect(!model.hasNextPage)
    }

    @Test("Invalid object input fails before reaching the broker")
    func invalidTarget() async throws {
        let sender = DatabaseDataScriptedSender(responses: [])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .elasticsearch)
        model.prepare(for: connection)

        model.browse(connection)

        #expect(model.state == .failed("Enter one index name, such as products."))
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test("Row editor creates canonical update, insert, and delete requests")
    func rowMutationRequests() async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)])
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.targetText = "public.customers"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.selectRecord(at: 0)
        model.beginEditingSelectedRow(connection)
        model.updateEditorField("name", text: "Updated")
        let update = try #require(model.editorMutationRequest(connection))
        #expect(
            update.payload.command
                == "UPDATE \"public\".\"customers\" SET \"name\" = $1 WHERE \"id\" IS NOT DISTINCT FROM $2 RETURNING 1"
        )
        #expect(update.payload.parameters.map(\.value) == [.string("Updated")])
        #expect(update.target.record?.components.first?.value == .signedInteger(1))

        let delete = try #require(model.deleteMutationRequest(connection))
        #expect(
            delete.payload.command
                == "DELETE FROM \"public\".\"customers\" WHERE \"id\" IS NOT DISTINCT FROM $1 RETURNING 1"
        )

        model.beginInsert(connection)
        model.updateEditorField("name", text: "Created")
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(
            insert.payload.command
                == "INSERT INTO \"public\".\"customers\" (\"name\") VALUES ($1) RETURNING 1"
        )
        #expect(insert.payload.parameters.map(\.value) == [.string("Created")])
        #expect(insert.target.record == nil)
    }

    @Test("Inline editing protects identity fields and creates a reviewed mutation")
    func inlineEditing() async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)])
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.targetText = "public.customers"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        #expect(!model.canEdit(recordAt: 0, field: "id", connection: connection))
        #expect(model.canEdit(recordAt: 0, field: "name", connection: connection))
        let mutation = try #require(
            model.inlineMutationRequest(
                recordAt: 0,
                field: "name",
                text: "Inline",
                connection: connection))
        #expect(
            mutation.payload.command
                == "UPDATE \"public\".\"customers\" SET \"name\" = $1 WHERE \"id\" IS NOT DISTINCT FROM $2 RETURNING 1"
        )
        #expect(mutation.payload.parameters.map(\.value) == [.string("Inline")])
    }

    private static func connection(
        product: DatabaseProduct
    ) throws -> DatabaseConnectionSummary {
        DatabaseConnectionSummary(
            definition: DatabaseConnectionDefinition(
                id: DatabaseConnectionID(
                    rawValue: UUID(uuidString: "86DFA58A-C6A6-498C-AE13-C66BB49CF891")!),
                displayName: "Data workspace",
                productHint: product,
                location: .network([
                    DatabaseNetworkEndpoint(host: "db.internal", port: try DatabasePort(5_432))
                ]),
                namespaces: DatabaseNamespaceDefaults(schema: "public", database: "app"),
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

    private static func record(_ identifier: Int64) -> DatabaseRecord {
        DatabaseRecord(
            identity: DatabaseRecordIdentity(
                kind: .primaryKey,
                components: [
                    DatabaseIdentityComponent(name: "id", value: .signedInteger(identifier))
                ]),
            fields: [
                DatabaseObjectField(name: "id", value: .signedInteger(identifier)),
                DatabaseObjectField(name: "name", value: .string("Customer \(identifier)")),
            ])
    }

    private static func response(
        records: [DatabaseRecord],
        nextContinuation: DatabaseContinuationToken? = nil
    ) -> DatabaseBrokerCommandResponse {
        let completeness = DatabaseResultCompleteness(state: .complete)
        let page = DatabasePage(
            records: records,
            fields: [
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("id"),
                    displayName: "id",
                    typeName: "bigint",
                    isNullable: false,
                    isSortable: true,
                    isFilterable: true),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("name"),
                    displayName: "name",
                    typeName: "text",
                    isNullable: false,
                    isSortable: true,
                    isFilterable: true),
            ],
            nextContinuation: nextContinuation,
            metadata: DatabasePageMetadata(
                completeness: completeness,
                count: DatabaseCountMetadata(value: UInt64(records.count), accuracy: .exact)))
        return .browse(
            .success(
                DatabaseBrowseResult(page: page),
                metadata: DatabaseResultMetadata(completeness: completeness)))
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("The data workspace did not reach the expected state.")
    }
}

private actor DatabaseDataScriptedSender: DatabaseBrokerCommandSending {
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
