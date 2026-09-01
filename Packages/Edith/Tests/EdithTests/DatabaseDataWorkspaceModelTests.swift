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

    @Test("Row editor only reviews fields that changed")
    func rowEditorChangeTracking() async throws {
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
        #expect(!model.canSubmitEditor)

        model.updateEditorField("name", text: "Updated")
        #expect(model.canSubmitEditor)
        #expect(model.editorFields.first(where: { $0.id == "name" })?.isIncluded == true)

        model.updateEditorField("name", text: "Customer 1")
        #expect(!model.canSubmitEditor)
        #expect(model.editorFields.first(where: { $0.id == "name" })?.isIncluded == false)

        model.updateEditorField("name", text: "Updated again")
        model.resetEditorField("name")
        #expect(!model.canSubmitEditor)
        #expect(model.editorFields.first(where: { $0.id == "name" })?.text == "Customer 1")

        model.beginInsert(connection)
        model.setEditorFieldIncluded("name", included: true)
        #expect(model.canSubmitEditor)
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(insert.payload.parameters.map(\.value) == [.string("")])
    }

    @Test("Redis key editor creates guarded string, TTL, and delete requests")
    func redisKeyMutationRequests() async throws {
        let sender = DatabaseDataScriptedSender(responses: [Self.redisResponse()])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .redis)
        model.prepare(for: connection)
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.beginInsert(connection)
        model.updateEditorField("key", text: "session:2")
        model.updateEditorField("value", text: "draft")
        model.updateEditorField("ttlMilliseconds", text: "120000")
        #expect(model.canSubmitEditor)
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(insert.payload.command == "SET")
        #expect(insert.payload.parameters.map(\.name) == ["key", "value", "ttlMilliseconds"])
        #expect(
            insert.payload.parameters.map(\.value)
                == [.string("session:2"), .string("draft"), .signedInteger(120_000)])

        model.cancelEditor()
        model.selectRecord(at: 0)
        #expect(!model.canEdit(recordAt: 0, field: "key", connection: connection))
        #expect(!model.canEdit(recordAt: 0, field: "type", connection: connection))
        #expect(model.canEdit(recordAt: 0, field: "value", connection: connection))
        #expect(model.canEdit(recordAt: 0, field: "ttlMilliseconds", connection: connection))
        model.beginEditingSelectedRow(connection)
        model.updateEditorField("value", text: "ready")
        model.updateEditorField("ttlMilliseconds", text: "-1")
        let update = try #require(model.editorMutationRequest(connection))
        #expect(update.payload.command == "SET")
        #expect(update.payload.parameters.map(\.name) == ["key", "value", "ttlPolicy"])
        #expect(update.payload.parameters.last?.value == .string("persistent"))

        let deletion = try #require(model.deleteMutationRequest(connection))
        #expect(deletion.payload.command == "DEL")
        #expect(deletion.payload.parameters.map(\.value) == [.string("session:1")])
    }

    @Test("MongoDB document editor creates guarded insert, update, and delete requests")
    func mongoDBDocumentMutationRequests() async throws {
        let sender = DatabaseDataScriptedSender(responses: [Self.mongoDBResponse()])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .mongoDB)
        model.prepare(for: connection)
        model.targetText = "app.people"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.selectRecord(at: 0)
        #expect(model.documentSource(try #require(model.selectedRecord))?.contains("$oid") == true)
        model.beginEditingSelectedRow(connection)
        #expect(model.documentText.contains("Ada"))
        model.updateDocumentText(
            """
            {"active": true, "name": "Ada Lovelace", "tags": ["math", "code"]}
            """)
        let update = try #require(model.editorMutationRequest(connection))
        #expect(update.payload.command == "updateOne")
        #expect(update.target.record?.kind == .documentID)
        #expect(update.payload.body?.objectFields?.map(\.name) == ["active", "name", "tags"])

        let deletion = try #require(model.deleteMutationRequest(connection))
        #expect(deletion.payload.command == "deleteOne")

        model.beginInsert(connection)
        model.updateDocumentText("{\"name\":\"Grace Hopper\",\"active\":true}")
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(insert.payload.command == "insertOne")
        #expect(insert.target.record == nil)
        #expect(insert.payload.body?.objectFields?.count == 2)
    }

    @Test("Elasticsearch document editor preserves source JSON and concurrency guards")
    func elasticsearchDocumentMutationRequests() async throws {
        let sender = DatabaseDataScriptedSender(responses: [Self.elasticsearchResponse()])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .elasticsearch)
        model.prepare(for: connection)
        model.targetText = "edith-documents-v1"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.selectRecord(at: 0)
        let selectedRecord = try #require(model.selectedRecord)
        let source = try #require(model.documentSource(selectedRecord))
        #expect(source.contains("\"_id\" : \"doc-1\""))
        #expect(!source.contains("_highlight"))
        #expect(!model.canEdit(recordAt: 0, field: "title", connection: connection))
        model.beginEditingSelectedRow(connection)
        model.updateDocumentText(
            """
            {"_id":"doc-1","event":{"$date":"literal"},"title":"updated"}
            """)
        let update = try #require(model.editorMutationRequest(connection))
        #expect(update.payload.command == "replace")
        #expect(update.target.record?.kind == .searchDocument)
        #expect(update.target.record?.concurrencyTokens.count == 2)
        #expect(update.payload.body?.objectFields?.contains(where: { $0.name == "_id" }) == false)
        #expect(
            update.payload.body?.objectFields?.first(where: { $0.name == "event" })?.value
                == .object([
                    DatabaseObjectField(name: "$date", value: .string("literal"))
                ]))

        let deletion = try #require(model.deleteMutationRequest(connection))
        #expect(deletion.payload.command == "delete")
        #expect(deletion.target.record?.concurrencyTokens.count == 2)

        model.beginInsert(connection)
        model.updateDocumentText("{\"_id\":\"doc-new\",\"title\":\"created\"}")
        #expect(model.canSubmitEditor)
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(insert.payload.command == "create")
        #expect(insert.target.record?.components.last?.value == .string("doc-new"))
        #expect(insert.target.record?.concurrencyTokens.isEmpty == true)
        #expect(insert.payload.body?.objectFields?.map(\.name) == ["title"])

        model.cancelEditor()
        model.beginEditingSelectedRow(connection)
        model.updateDocumentText("{\"_id\":\"other\",\"title\":\"unsafe\"}")
        #expect(model.editorMutationRequest(connection) == nil)
        #expect(model.editorError == "The document identifier cannot be changed while editing.")
    }

    @Test("Elasticsearch editor restores its product context when opened")
    func elasticsearchEditorRestoresProductContext() throws {
        let model = DatabaseDataWorkspaceModel(announcement: { _ in })
        let connection = try Self.connection(product: .elasticsearch)

        model.beginInsert(connection)

        #expect(model.canSubmitEditor)
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

    private static func redisResponse() -> DatabaseBrokerCommandResponse {
        let record = DatabaseRecord(
            identity: DatabaseRecordIdentity(
                kind: .key,
                components: [
                    DatabaseIdentityComponent(name: "key", value: .string("session:1"))
                ]),
            fields: [
                DatabaseObjectField(name: "key", value: .string("session:1")),
                DatabaseObjectField(name: "type", value: .string("string")),
                DatabaseObjectField(name: "ttlMilliseconds", value: .signedInteger(60_000)),
                DatabaseObjectField(name: "length", value: .unsignedInteger(5)),
                DatabaseObjectField(name: "value", value: .string("draft")),
            ])
        let page = DatabasePage(
            records: [record],
            fields: [
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("key"), displayName: "Key", typeName: "bytes",
                    isNullable: false, isSortable: false, isFilterable: false),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("type"), displayName: "Type", typeName: "string",
                    isNullable: false, isSortable: false, isFilterable: false),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("ttlMilliseconds"), displayName: "TTL milliseconds",
                    typeName: "int64", isNullable: false, isSortable: false,
                    isFilterable: false),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("length"), displayName: "Length", typeName: "uint64",
                    isNullable: true, isSortable: false, isFilterable: false),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("value"), displayName: "Value", typeName: "native",
                    isNullable: true, isSortable: false, isFilterable: false),
            ],
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .sampled),
                count: DatabaseCountMetadata(value: nil, accuracy: .unknown)))
        return .browse(
            .success(
                DatabaseBrowseResult(page: page),
                metadata: DatabaseResultMetadata(completeness: page.metadata.completeness)))
    }

    private static func mongoDBResponse() -> DatabaseBrokerCommandResponse {
        let identifier = DatabaseValue.productSpecific(
            DatabaseProductValue(
                product: .mongoDB,
                typeName: "objectId",
                textRepresentation: "507f1f77bcf86cd799439011"))
        let record = DatabaseRecord(
            identity: DatabaseRecordIdentity(
                kind: .documentID,
                components: [DatabaseIdentityComponent(name: "_id", value: identifier)]),
            fields: [
                DatabaseObjectField(name: "name", value: .string("Ada")),
                DatabaseObjectField(name: "active", value: .boolean(true)),
                DatabaseObjectField(
                    name: "profile",
                    value: .object([
                        DatabaseObjectField(name: "language", value: .string("Swift"))
                    ])),
            ])
        let completeness = DatabaseResultCompleteness(state: .sampled)
        let page = DatabasePage(
            records: [record],
            fields: [
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("name"), displayName: "name", typeName: "string",
                    isNullable: true, isSortable: true, isFilterable: true),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("active"), displayName: "active", typeName: "boolean",
                    isNullable: true, isSortable: true, isFilterable: true),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("profile"), displayName: "profile", typeName: "object",
                    isNullable: true, isSortable: false, isFilterable: false),
            ],
            metadata: DatabasePageMetadata(
                completeness: completeness,
                count: DatabaseCountMetadata(value: nil, accuracy: .estimated)))
        return .browse(
            .success(
                DatabaseBrowseResult(page: page),
                metadata: DatabaseResultMetadata(completeness: completeness)))
    }

    private static func elasticsearchResponse() -> DatabaseBrokerCommandResponse {
        let record = DatabaseRecord(
            identity: DatabaseRecordIdentity(
                kind: .searchDocument,
                components: [
                    DatabaseIdentityComponent(
                        name: "_index",
                        value: .string("edith-documents-v1")),
                    DatabaseIdentityComponent(name: "_id", value: .string("doc-1")),
                ],
                concurrencyTokens: [
                    DatabaseIdentityComponent(name: "_seq_no", value: .signedInteger(7)),
                    DatabaseIdentityComponent(name: "_primary_term", value: .signedInteger(2)),
                ]),
            fields: [
                DatabaseObjectField(name: "title", value: .string("before")),
                DatabaseObjectField(
                    name: "event",
                    value: .object([
                        DatabaseObjectField(name: "$date", value: .string("literal"))
                    ])),
                DatabaseObjectField(
                    name: "_highlight",
                    value: .object([
                        DatabaseObjectField(
                            name: "title",
                            value: .array([.string("<em>before</em>")]))
                    ])),
            ])
        let completeness = DatabaseResultCompleteness(state: .sampled)
        let page = DatabasePage(
            records: [record],
            fields: [
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("title"), displayName: "title", typeName: "text",
                    isNullable: true, isSortable: false, isFilterable: true),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("event"), displayName: "event", typeName: "object",
                    isNullable: true, isSortable: false, isFilterable: false),
            ],
            metadata: DatabasePageMetadata(
                completeness: completeness,
                count: DatabaseCountMetadata(value: 1, accuracy: .exact)))
        return .browse(
            .success(
                DatabaseBrowseResult(page: page),
                metadata: DatabaseResultMetadata(completeness: completeness)))
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

private extension DatabaseValue {
    var objectFields: [DatabaseObjectField]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }
}
