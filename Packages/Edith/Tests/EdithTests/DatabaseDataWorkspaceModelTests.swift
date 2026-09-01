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
        model.addFilterClause(
            field: "customer_name",
            operation: .contains,
            valueText: "Ada",
            caseSensitivity: .insensitive)
        model.setSort(field: "created_at", direction: .descending, additive: false)

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

    @Test("Exact sort direction replaces or preserves ordered priority")
    func exactSortDirection() {
        let model = DatabaseDataWorkspaceModel(announcement: { _ in })

        model.setSort(field: "created_at", direction: .descending, additive: false)
        #expect(model.orderedSorts.map(\.summary) == ["created_at descending"])

        model.setSort(field: "id", direction: .ascending, additive: true)
        #expect(
            model.orderedSorts.map(\.summary)
                == ["created_at descending", "id ascending"])

        model.setSort(field: "created_at", direction: .ascending, additive: true)
        #expect(
            model.orderedSorts.map(\.summary)
                == ["created_at ascending", "id ascending"])

        model.setSort(field: "name", direction: .descending, additive: false)
        #expect(model.orderedSorts.map(\.summary) == ["name descending"])
    }

    @Test("Structured filters build one conjunction level with ordered typed sorts")
    func structuredFiltersAndOrderedSorts() async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)]),
            Self.response(records: [Self.record(42)]),
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.targetText = "analytics.orders"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        let identifier = model.addFilterClause(
            field: "id",
            operation: .equal,
            valueText: "42")
        let nameIdentifier = model.addFilterClause(field: "name", valueText: "Ada")
        model.addFilterClause(
            field: "ignored",
            operation: .equal,
            valueText: "unused",
            isEnabled: false)
        model.setFilterConjunction(.or)
        model.cycleSort(field: "name", additive: false)
        model.cycleSort(field: "id", additive: true)
        model.cycleSort(field: "id", additive: true)

        #expect(model.filterClauses[0].id == identifier)
        #expect(model.filterClauses[1].id == nameIdentifier)
        #expect(model.filterClauses[1].operation == .contains)
        #expect(model.filterClauses[1].caseSensitivity == .insensitive)
        #expect(model.activeFilterCount == 2)
        #expect(model.activeFilterSummary == "2 filters, match any")
        #expect(model.activeSortSummary == "name ascending, id descending")

        model.browse(connection)
        await Self.waitUntil { model.state == .loaded && model.records == [Self.record(42)] }

        let requests = await sender.recordedRequests().compactMap(\.browseRequest)
        let request = try #require(requests.last)
        #expect(
            request.page.filter
                == .any([
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("id"),
                            operation: .equal,
                            values: [.signedInteger(42)])),
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("name"),
                            operation: .contains,
                            values: [.string("Ada")],
                            caseSensitivity: .insensitive)),
                ]))
        #expect(
            request.page.sorts
                == [
                    DatabaseSort(field: DatabaseFieldPath("name"), direction: .ascending),
                    DatabaseSort(field: DatabaseFieldPath("id"), direction: .descending),
                ])
    }

    @Test("Filter and sort changes reset paging while sort cycling preserves priority")
    func filterAndSortPagingReset() async throws {
        let token = DatabaseContinuationToken(rawValue: "next-page")
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)], nextContinuation: token)
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.targetText = "public.customers"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded && model.hasNextPage }

        model.cycleSort(field: "name", additive: false)
        #expect(!model.hasNextPage)
        #expect(model.orderedSorts.map(\.summary) == ["name ascending"])

        model.cycleSort(field: "id", additive: true)
        model.cycleSort(field: "name", additive: true)
        #expect(model.orderedSorts.map(\.summary) == ["name descending", "id ascending"])

        model.cycleSort(field: "name", additive: true)
        #expect(model.orderedSorts.map(\.summary) == ["id ascending"])

        model.cycleSort(field: "id", additive: false)
        #expect(model.orderedSorts.map(\.summary) == ["id descending"])
        model.cycleSort(field: "id", additive: false)
        #expect(model.orderedSorts.isEmpty)

        let filterID = model.addFilterClause(field: "name", valueText: "Ada")
        var clause = try #require(model.filterClauses.first(where: { $0.id == filterID }))
        #expect(clause.summary == "name contains Ada")
        clause.isEnabled = false
        model.updateFilterClause(clause)
        #expect(model.activeFilterSummary == "No active filters")
    }

    @Test("Invalid structured filter values fail before a new broker request")
    func invalidStructuredFilter() async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)])
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.targetText = "public.customers"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }
        model.addFilterClause(field: "id", operation: .between, valueText: "1")

        model.browse(connection)

        #expect(
            model.state
                == .failed("Enter two comma-separated values for the id filter."))
        #expect(await sender.recordedRequests().count == 1)
    }

    @Test("MongoDB objectId filters preserve their native value type")
    func mongoDBObjectIDFilter() async throws {
        let fields = [
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("_id"),
                displayName: "_id",
                typeName: "objectId",
                isNullable: false,
                isSortable: true,
                isFilterable: true)
        ]
        let response = Self.response(records: [], fields: fields)
        let sender = DatabaseDataScriptedSender(responses: [response, response])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .mongoDB)
        model.prepare(for: connection)
        model.targetText = "app.people"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.addFilterClause(
            field: "_id",
            operation: .equal,
            valueText: "507f1f77bcf86cd799439011")
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        let requests = await sender.recordedRequests().compactMap(\.browseRequest)
        #expect(
            requests.last?.page.filter
                == .predicate(
                    DatabaseFilterPredicate(
                        field: DatabaseFieldPath("_id"),
                        operation: .equal,
                        values: [
                            .productSpecific(
                                DatabaseProductValue(
                                    product: .mongoDB,
                                    typeName: "objectId",
                                    textRepresentation: "507f1f77bcf86cd799439011"))
                        ])))

        model.clearFilters()
        model.addFilterClause(field: "_id", operation: .equal, valueText: "not-an-object-id")
        model.browse(connection)
        #expect(model.state == .failed("Enter a valid objectId value for the _id filter."))
        #expect(await sender.recordedRequests().count == 2)
    }

    @Test(
        "Search mapping numeric filters produce exact database value types",
        arguments: [DatabaseProduct.elasticsearch, .openSearch]
    )
    func searchNumericFilters(product: DatabaseProduct) async throws {
        let fields = [
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("event_count"), displayName: "event_count",
                typeName: "long", isNullable: false, isSortable: true, isFilterable: true),
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("priority"), displayName: "priority",
                typeName: "short", isNullable: false, isSortable: true, isFilterable: true),
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("status_code"), displayName: "status_code",
                typeName: "byte", isNullable: false, isSortable: true, isFilterable: true),
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("score"), displayName: "score",
                typeName: "float", isNullable: false, isSortable: true, isFilterable: true),
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("ratio"), displayName: "ratio",
                typeName: "half_float", isNullable: false, isSortable: true, isFilterable: true),
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("price"), displayName: "price",
                typeName: "scaled_float", isNullable: false, isSortable: true, isFilterable: true),
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("total"), displayName: "total",
                typeName: "unsigned_long", isNullable: false, isSortable: true,
                isFilterable: true),
        ]
        let response = Self.response(records: [], fields: fields)
        let sender = DatabaseDataScriptedSender(responses: [response, response])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: product)
        model.prepare(for: connection)
        model.targetText = "events-v1"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.addFilterClause(field: "event_count", operation: .equal, valueText: "-42")
        model.addFilterClause(field: "priority", operation: .equal, valueText: "12")
        model.addFilterClause(field: "status_code", operation: .equal, valueText: "127")
        model.addFilterClause(field: "score", operation: .equal, valueText: "1.25")
        model.addFilterClause(field: "ratio", operation: .equal, valueText: "-2.5")
        model.addFilterClause(field: "price", operation: .equal, valueText: "42.125")
        model.addFilterClause(
            field: "total",
            operation: .equal,
            valueText: "18446744073709551615")
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        let request = try #require(
            await sender.recordedRequests().compactMap(\.browseRequest).last)
        #expect(
            request.page.filter
                == .all([
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("event_count"), operation: .equal,
                            values: [.signedInteger(-42)])),
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("priority"), operation: .equal,
                            values: [.signedInteger(12)])),
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("status_code"), operation: .equal,
                            values: [.signedInteger(127)])),
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("score"), operation: .equal,
                            values: [.floatingPoint(1.25)])),
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("ratio"), operation: .equal,
                            values: [.floatingPoint(-2.5)])),
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("price"), operation: .equal,
                            values: [.floatingPoint(42.125)])),
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("total"), operation: .equal,
                            values: [.unsignedInteger(UInt64.max)])),
                ]))
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

    @Test("Changing filters cancels a stale automatic page and starts fresh")
    func filterChangeCancelsAutomaticPage() async throws {
        let token = DatabaseContinuationToken(rawValue: "next-page")
        let sender = DatabaseDataControlledSender()
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.targetText = "public.customers"

        model.browse(connection)
        await Self.waitUntilRequestCount(1, sender: sender)
        await sender.respond(
            Self.response(records: [Self.record(1)], nextContinuation: token),
            to: 0)
        await Self.waitUntil { model.state == .loaded && model.hasNextPage }

        model.loadNextPage(connection)
        await Self.waitUntilRequestCount(2, sender: sender)
        model.addFilterClause(field: "name", operation: .contains, valueText: "Ada")
        model.browse(connection)
        await Self.waitUntilRequestCount(3, sender: sender)
        await sender.respond(Self.response(records: [Self.record(42)]), to: 2)
        await Self.waitUntil { model.state == .loaded && model.records == [Self.record(42)] }

        await sender.respond(Self.response(records: [Self.record(2)]), to: 1)
        for _ in 0..<100 {
            await Task.yield()
        }

        let requests = await sender.recordedRequests().compactMap(\.browseRequest)
        #expect(requests.count == 3)
        #expect(requests[1].page.continuation == token)
        #expect(requests[2].page.continuation == nil)
        #expect(requests[2].page.filter != nil)
        #expect(model.records == [Self.record(42)])
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

    @Test(
        "PostgreSQL, MySQL, and SQLite queries map to exact SQL requests",
        arguments: [DatabaseProduct.postgresql, .mysql, .sqlite]
    )
    func relationalQueryRequests(product: DatabaseProduct) async throws {
        let captured = try await Self.capturedQuery(
            product: product,
            text: "  SELECT id, name FROM customers ORDER BY id  ")

        #expect(
            captured.request
                == DatabaseQueryRequest(
                    target: DatabaseTargetIdentifier(connectionID: captured.connection.id),
                    language: .sql,
                    command: "SELECT id, name FROM customers ORDER BY id",
                    page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
                    operation: captured.request.operation))
    }

    @Test(
        "Redis and Valkey queries split the command and key into an exact request",
        arguments: [DatabaseProduct.redis, .valkey]
    )
    func keyspaceQueryRequests(product: DatabaseProduct) async throws {
        let object = DatabaseObjectIdentifier(kind: .keyspace, path: ["3"])
        let captured = try await Self.capturedQuery(
            product: product,
            object: object,
            text: "  GET   session:customer:1  ")

        #expect(
            captured.request
                == DatabaseQueryRequest(
                    target: DatabaseTargetIdentifier(
                        connectionID: captured.connection.id,
                        object: object),
                    language: .redisCommand,
                    command: "GET",
                    parameters: [
                        DatabaseQueryParameter(
                            name: "key",
                            value: .string("session:customer:1"))
                    ],
                    page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
                    operation: captured.request.operation))
    }

    @Test("MongoDB query maps extended JSON into native database values")
    func mongoDBQueryRequest() async throws {
        let object = DatabaseObjectIdentifier(kind: .collection, path: ["app", "people"])
        let captured = try await Self.capturedQuery(
            product: .mongoDB,
            object: object,
            text:
                """
                {"_id":{"$oid":"507f1f77bcf86cd799439011"},"createdAt":{"$date":"2024-01-02T03:04:05Z"}}
                """)

        #expect(
            captured.request
                == DatabaseQueryRequest(
                    target: DatabaseTargetIdentifier(
                        connectionID: captured.connection.id,
                        object: object),
                    language: .mongoQuery,
                    command: "find",
                    body: .object([
                        DatabaseObjectField(
                            name: "_id",
                            value: .productSpecific(
                                DatabaseProductValue(
                                    product: .mongoDB,
                                    typeName: "objectId",
                                    textRepresentation: "507f1f77bcf86cd799439011"))),
                        DatabaseObjectField(
                            name: "createdAt",
                            value: .timestamp(
                                DatabaseTimestampValue(text: "2024-01-02T03:04:05Z"))),
                    ]),
                    page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
                    operation: captured.request.operation))
    }

    @Test(
        "Elasticsearch and OpenSearch preserve dollar keys for search and aggregate commands",
        arguments: [DatabaseProduct.elasticsearch, .openSearch]
    )
    func searchQueryRequests(product: DatabaseProduct) async throws {
        let object = DatabaseObjectIdentifier(kind: .index, path: ["events-v1"])
        let body = DatabaseValue.object([
            DatabaseObjectField(
                name: "event",
                value: .object([
                    DatabaseObjectField(name: "$date", value: .string("literal"))
                ]))
        ])
        let search = try await Self.capturedQuery(
            product: product,
            object: object,
            text: "{\"event\":{\"$date\":\"literal\"}}")
        let aggregate = try await Self.capturedQuery(
            product: product,
            object: object,
            text: "{\"event\":{\"$date\":\"literal\"}}",
            operation: .aggregate)

        #expect(
            search.request
                == DatabaseQueryRequest(
                    target: DatabaseTargetIdentifier(
                        connectionID: search.connection.id,
                        object: object),
                    language: .searchQueryDSL,
                    command: "search",
                    body: body,
                    page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
                    operation: search.request.operation))
        #expect(
            aggregate.request
                == DatabaseQueryRequest(
                    target: DatabaseTargetIdentifier(
                        connectionID: aggregate.connection.id,
                        object: object),
                    language: .searchQueryDSL,
                    command: "aggregate",
                    body: body,
                    page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
                    operation: aggregate.request.operation))
    }

    @Test("ClickHouse query maps to an exact native SQL request")
    func clickHouseQueryRequest() async throws {
        let captured = try await Self.capturedQuery(
            product: .clickHouse,
            text: "  SELECT count() FROM app.events  ")

        #expect(
            captured.request
                == DatabaseQueryRequest(
                    target: DatabaseTargetIdentifier(connectionID: captured.connection.id),
                    language: .clickHouseSQL,
                    command: "SELECT count() FROM app.events",
                    page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
                    operation: captured.request.operation))
    }

    @Test("Invalid query input fails before reaching the broker")
    func invalidQuery() async throws {
        let sender = DatabaseDataScriptedSender(responses: [])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.queryText = " \n\t "

        model.runQuery(connection)

        #expect(model.state == .failed("Enter a query to run."))
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test("Query continuation appends and replays the original request")
    func continuationQuery() async throws {
        let token = DatabaseContinuationToken(rawValue: "query-next-page")
        let sender = DatabaseDataScriptedSender(
            responses: [
                Self.queryResponse(records: [Self.record(1)], nextContinuation: token),
                Self.queryResponse(records: [Self.record(2)]),
            ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.queryText = "SELECT * FROM public.customers ORDER BY id"

        model.runQuery(connection)
        await Self.waitUntil { model.state == .loaded && model.hasNextPage }
        model.queryText = "SELECT * FROM public.orders"
        model.loadNextPage(connection)
        await Self.waitUntil { model.state == .loaded && model.records.count == 2 }

        let requests = await sender.recordedRequests().compactMap(\.queryRequest)
        #expect(requests.count == 2)
        #expect(requests[0].page.continuation == nil)
        #expect(requests[1].page.continuation == token)
        #expect(requests[1].command == requests[0].command)
        #expect(requests[1].target == requests[0].target)
        #expect(requests[1].language == requests[0].language)
        #expect(requests[1].parameters == requests[0].parameters)
        #expect(requests[1].body == requests[0].body)
        #expect(model.records == [Self.record(1), Self.record(2)])
    }

    @Test("Query response type mismatch fails closed")
    func queryResponseTypeMismatch() async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)])
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .postgresql)
        model.prepare(for: connection)
        model.queryText = "SELECT * FROM public.customers"

        model.runQuery(connection)
        await Self.waitUntil { model.state != .loading }

        #expect(model.state == .failed("The database returned an unexpected data response."))
        #expect(model.records.isEmpty)
    }

    @Test("Default relational query templates quote every identifier")
    func defaultQueryTemplatesQuoteIdentifiers() throws {
        let scenarios: [(DatabaseProduct, DatabaseObjectIdentifier, String)] = [
            (
                .postgresql,
                DatabaseObjectIdentifier(kind: .table, path: ["sales", "order\"items"]),
                "SELECT * FROM \"sales\".\"order\"\"items\""
            ),
            (
                .sqlite,
                DatabaseObjectIdentifier(kind: .table, path: ["order\"items"]),
                "SELECT * FROM \"order\"\"items\""
            ),
            (
                .mysql,
                DatabaseObjectIdentifier(kind: .table, path: ["sales", "order`items"]),
                "SELECT * FROM `sales`.`order``items`"
            ),
            (
                .clickHouse,
                DatabaseObjectIdentifier(kind: .table, path: ["sales", "order`items"]),
                "SELECT * FROM `sales`.`order``items`"
            ),
        ]

        for (product, object, expected) in scenarios {
            let model = DatabaseDataWorkspaceModel(announcement: { _ in })
            let connection = try Self.connection(product: product)
            model.prepare(for: connection)
            model.prepareQuery(object, connection: connection)

            #expect(model.queryText == expected)
        }
    }

    @Test("Cancelled stale query response cannot replace current results")
    func staleQueryResponse() async throws {
        let sender = DatabaseDataControlledSender()
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let firstConnection = try Self.connection(product: .postgresql)
        let secondConnection = try Self.connection(
            id: DatabaseConnectionID(
                rawValue: UUID(uuidString: "11309269-B668-4E06-B189-0282821598FE")!),
            product: .postgresql)
        model.prepare(for: firstConnection)
        model.queryText = "SELECT * FROM public.old_records"
        model.runQuery(firstConnection)
        await Self.waitUntilRequestCount(1, sender: sender)

        model.prepare(for: secondConnection)
        model.queryText = "SELECT * FROM public.current_records"
        model.runQuery(secondConnection)
        await Self.waitUntilRequestCount(2, sender: sender)
        await sender.respond(Self.queryResponse(records: [Self.record(2)]), to: 1)
        await Self.waitUntil { model.state == .loaded }

        await sender.respond(Self.queryResponse(records: [Self.record(1)]), to: 0)
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(model.records == [Self.record(2)])
        #expect(model.state == .loaded)
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

    @Test(
        "MySQL-family row editor creates bounded canonical mutations",
        arguments: [DatabaseProduct.mysql, .mariaDB]
    )
    func mySQLFamilyMutationRequests(product: DatabaseProduct) async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)])
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: product)
        model.prepare(for: connection)
        model.targetText = "commerce.customers"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.selectRecord(at: 0)
        model.beginEditingSelectedRow(connection)
        model.updateEditorField("name", text: "Updated")
        let update = try #require(model.editorMutationRequest(connection))
        #expect(
            update.payload.command
                == "UPDATE `commerce`.`customers` SET `name` = ? WHERE `id` <=> ? LIMIT 1")
        #expect(update.payload.product == product)
        #expect(update.payload.parameters.map(\.value) == [.string("Updated")])

        let deletion = try #require(model.deleteMutationRequest(connection))
        #expect(
            deletion.payload.command
                == "DELETE FROM `commerce`.`customers` WHERE `id` <=> ? LIMIT 1")
        #expect(deletion.payload.product == product)

        model.beginInsert(connection)
        model.updateEditorField("name", text: "Created")
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(insert.payload.command == "INSERT INTO `commerce`.`customers` (`name`) VALUES (?)")
        #expect(insert.payload.product == product)
        #expect(insert.payload.parameters.map(\.value) == [.string("Created")])
    }

    @Test("SQLite row editor creates identity-bounded canonical mutations")
    func sqliteMutationRequests() async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)])
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .sqlite)
        model.prepare(for: connection)
        model.targetText = "customers"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.selectRecord(at: 0)
        model.beginEditingSelectedRow(connection)
        model.updateEditorField("name", text: "Updated")
        let update = try #require(model.editorMutationRequest(connection))
        #expect(
            update.payload.command
                == "UPDATE \"main\".\"customers\" SET \"name\" = ? WHERE \"id\" IS ?")
        #expect(update.payload.product == .sqlite)
        #expect(update.payload.parameters.map(\.value) == [.string("Updated")])

        let deletion = try #require(model.deleteMutationRequest(connection))
        #expect(
            deletion.payload.command
                == "DELETE FROM \"main\".\"customers\" WHERE \"id\" IS ?")
        #expect(deletion.payload.product == .sqlite)

        model.beginInsert(connection)
        model.updateEditorField("name", text: "Created")
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(
            insert.payload.command
                == "INSERT INTO \"main\".\"customers\" (\"name\") VALUES (?)")
        #expect(insert.payload.product == .sqlite)
        #expect(insert.payload.parameters.map(\.value) == [.string("Created")])
    }

    @Test("ClickHouse editor creates inserts and keeps row changes unavailable")
    func clickHouseMutationRequests() async throws {
        let sender = DatabaseDataScriptedSender(responses: [
            Self.response(records: [Self.record(1)])
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .clickHouse)
        model.prepare(for: connection)
        model.targetText = "analytics.events"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        #expect(model.supportsDataMutation(.insert, connection: connection))
        #expect(!model.supportsDataMutation(.update, connection: connection))
        #expect(!model.supportsDataMutation(.delete, connection: connection))
        model.beginInsert(connection)
        model.updateEditorField("id", text: "42")
        model.updateEditorField("name", text: "signup")
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(
            insert.payload.command
                == "INSERT INTO `analytics`.`events` (`id`, `name`) VALUES (?, ?)")
        #expect(insert.payload.product == .clickHouse)
        #expect(insert.payload.parameters.map(\.value) == [.signedInteger(42), .string("signup")])

        model.cancelEditor()
        model.selectRecord(at: 0)
        model.beginEditingSelectedRow(connection)
        #expect(model.editorMode == nil)
        #expect(model.editorError?.contains("cannot be targeted uniquely") == true)
        #expect(model.deleteMutationRequest(connection) == nil)
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

    @Test("MongoDB mutation eligibility requires a round-trippable document identity")
    func mongoDBMutationEligibility() async throws {
        let previewIdentity = DatabaseValue.productSpecific(
            DatabaseProductValue(
                product: .mongoDB,
                typeName: "valuePreview",
                textRepresentation: "unavailable"))
        let sender = DatabaseDataScriptedSender(responses: [
            Self.mongoDBResponse(identifier: previewIdentity)
        ])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .mongoDB)
        model.prepare(for: connection)
        model.targetText = "app.people"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.selectRecord(at: 0)
        #expect(!model.canMutateSelectedRecord(.update, connection: connection))
        #expect(!model.canMutateSelectedRecord(.delete, connection: connection))
        model.beginEditingSelectedRow(connection)
        #expect(model.editorMode == nil)
        #expect(model.editorError == "This record has no stable identity for safe editing.")
        #expect(model.deleteMutationRequest(connection) == nil)
    }

    @Test("MongoDB documents with unsupported values remain deletable but not editable")
    func mongoDBUnsupportedDocumentEditEligibility() async throws {
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
                DatabaseObjectField(name: "_id", value: identifier),
                DatabaseObjectField(
                    name: "clock",
                    value: .productSpecific(
                        DatabaseProductValue(
                            product: .mongoDB,
                            typeName: "bsonTimestamp",
                            textRepresentation: "10:2"))),
            ])
        let sender = DatabaseDataScriptedSender(responses: [Self.response(records: [record])])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .mongoDB)
        model.prepare(for: connection)
        model.targetText = "app.people"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.selectRecord(at: 0)
        #expect(!model.canMutateSelectedRecord(.update, connection: connection))
        #expect(model.canMutateSelectedRecord(.delete, connection: connection))
        model.beginEditingSelectedRow(connection)
        #expect(model.editorMode == nil)
        #expect(model.deleteMutationRequest(connection)?.payload.command == "deleteOne")
    }

    @Test(
        "Search mutation eligibility requires the complete exact concurrency token pair",
        arguments: [DatabaseProduct.elasticsearch, .openSearch]
    )
    func searchMutationEligibility(product: DatabaseProduct) async throws {
        let incompleteTokens = [
            [DatabaseIdentityComponent(name: "_seq_no", value: .signedInteger(7))],
            [DatabaseIdentityComponent(name: "_primary_term", value: .signedInteger(2))],
            [
                DatabaseIdentityComponent(name: "_seq_no", value: .signedInteger(-1)),
                DatabaseIdentityComponent(name: "_primary_term", value: .signedInteger(2)),
            ],
            [
                DatabaseIdentityComponent(name: "_seq_no", value: .signedInteger(7)),
                DatabaseIdentityComponent(name: "_primary_term", value: .signedInteger(2)),
                DatabaseIdentityComponent(name: "_version", value: .signedInteger(3)),
            ],
        ]

        for concurrencyTokens in incompleteTokens {
            let sender = DatabaseDataScriptedSender(responses: [
                Self.elasticsearchResponse(concurrencyTokens: concurrencyTokens)
            ])
            let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
            let connection = try Self.connection(product: product)
            model.prepare(for: connection)
            model.targetText = "edith-documents-v1"
            model.browse(connection)
            await Self.waitUntil { model.state == .loaded }

            model.selectRecord(at: 0)
            #expect(!model.canMutateSelectedRecord(.update, connection: connection))
            #expect(!model.canMutateSelectedRecord(.delete, connection: connection))
            model.beginEditingSelectedRow(connection)
            #expect(model.editorMode == nil)
            #expect(model.deleteMutationRequest(connection) == nil)
        }
    }

    @Test("MongoDB editor submission requires canonical document JSON")
    func mongoDBEditorSubmissionValidation() async throws {
        let sender = DatabaseDataScriptedSender(responses: [Self.mongoDBResponse()])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .mongoDB)
        model.prepare(for: connection)
        model.targetText = "app.people"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.beginInsert(connection)
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("[]")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{}")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{\"$set\":1}")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{\"name\":\"Grace Hopper\"}")
        #expect(model.canSubmitEditor)

        model.cancelEditor()
        model.selectRecord(at: 0)
        model.beginEditingSelectedRow(connection)
        #expect(model.canSubmitEditor)
        model.updateDocumentText("{\"_id\":\"unsafe\"}")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{\"name\":\"Ada Lovelace\"}")
        #expect(model.canSubmitEditor)
    }

    @Test(
        "Search editor submission requires a canonical document payload",
        arguments: [DatabaseProduct.elasticsearch, .openSearch]
    )
    func searchEditorSubmissionValidation(product: DatabaseProduct) async throws {
        let sender = DatabaseDataScriptedSender(responses: [Self.elasticsearchResponse()])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: product)
        model.prepare(for: connection)
        model.targetText = "edith-documents-v1"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.beginInsert(connection)
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{\"title\":\"missing identity\"}")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{\"_id\":\"doc-new\",\"_seq_no\":1}")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{\"_id\":\"doc-new\",\"title\":\"created\"}")
        #expect(model.canSubmitEditor)

        model.cancelEditor()
        model.selectRecord(at: 0)
        model.beginEditingSelectedRow(connection)
        #expect(model.canSubmitEditor)
        model.updateDocumentText("{\"_id\":\"other\",\"title\":\"unsafe\"}")
        #expect(!model.canSubmitEditor)
        model.updateDocumentText("{\"_id\":\"doc-1\",\"title\":\"updated\"}")
        #expect(model.canSubmitEditor)
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
        #expect(model.canMutateSelectedRecord(.update, connection: connection))
        #expect(model.canMutateSelectedRecord(.delete, connection: connection))
        #expect(model.documentSource(try #require(model.selectedRecord))?.contains("$oid") == true)
        model.beginEditingSelectedRow(connection)
        #expect(model.documentText.contains("Ada"))
        #expect(!model.documentText.contains("_id"))
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
        #expect(model.canMutateSelectedRecord(.update, connection: connection))
        #expect(model.canMutateSelectedRecord(.delete, connection: connection))
        let selectedRecord = try #require(model.selectedRecord)
        let source = try #require(model.documentSource(selectedRecord))
        #expect(!source.contains("_id"))
        #expect(!source.contains("_highlight"))
        #expect(!model.canEdit(recordAt: 0, field: "title", connection: connection))
        model.beginEditingSelectedRow(connection)
        #expect(model.documentText.contains("\"_id\" : \"doc-1\""))
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
        model.prepare(for: connection)
        model.targetText = "edith-documents-v1"

        model.beginInsert(connection)
        model.updateDocumentText("{\"_id\":\"doc-new\",\"title\":\"created\"}")

        #expect(model.canSubmitEditor)
    }

    @Test("OpenSearch document editor creates guarded search mutations")
    func openSearchDocumentMutationRequests() async throws {
        let sender = DatabaseDataScriptedSender(responses: [Self.elasticsearchResponse()])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try Self.connection(product: .openSearch)
        model.prepare(for: connection)
        model.targetText = "edith-documents-v1"
        model.browse(connection)
        await Self.waitUntil { model.state == .loaded }

        model.selectRecord(at: 0)
        model.beginEditingSelectedRow(connection)
        model.updateDocumentText("{\"_id\":\"doc-1\",\"title\":\"updated\"}")
        let update = try #require(model.editorMutationRequest(connection))
        #expect(update.payload.product == .openSearch)
        #expect(update.payload.command == "replace")
        #expect(update.target.record?.concurrencyTokens.count == 2)

        let deletion = try #require(model.deleteMutationRequest(connection))
        #expect(deletion.payload.product == .openSearch)
        #expect(deletion.payload.command == "delete")

        model.beginInsert(connection)
        model.updateDocumentText("{\"_id\":\"doc-new\",\"title\":\"created\"}")
        let insert = try #require(model.editorMutationRequest(connection))
        #expect(insert.payload.product == .openSearch)
        #expect(insert.payload.command == "create")
        #expect(insert.target.record?.concurrencyTokens.isEmpty == true)
    }

    private static func capturedQuery(
        product: DatabaseProduct,
        object: DatabaseObjectIdentifier? = nil,
        text: String,
        operation: DatabaseSearchQueryOperation = .search
    ) async throws -> (request: DatabaseQueryRequest, connection: DatabaseConnectionSummary) {
        let sender = DatabaseDataScriptedSender(responses: [queryResponse(records: [])])
        let model = DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        let connection = try connection(product: product)
        model.prepare(for: connection)
        if let object {
            model.prepareQuery(object, connection: connection)
        }
        model.searchQueryOperation = operation
        model.queryText = text

        model.runQuery(connection)
        await waitUntil { model.state == .loaded }

        let request = try #require((await sender.recordedRequests()).first?.queryRequest)
        return (request, connection)
    }

    private static func connection(
        id: DatabaseConnectionID = DatabaseConnectionID(
            rawValue: UUID(uuidString: "86DFA58A-C6A6-498C-AE13-C66BB49CF891")!),
        product: DatabaseProduct
    ) throws -> DatabaseConnectionSummary {
        DatabaseConnectionSummary(
            definition: DatabaseConnectionDefinition(
                id: id,
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

    private static func mongoDBResponse(
        identifier: DatabaseValue? = nil
    ) -> DatabaseBrokerCommandResponse {
        let identifier =
            identifier
            ?? .productSpecific(
                DatabaseProductValue(
                    product: .mongoDB,
                    typeName: "objectId",
                    textRepresentation: "507f1f77bcf86cd799439011"))
        let record = DatabaseRecord(
            identity: DatabaseRecordIdentity(
                kind: .documentID,
                components: [DatabaseIdentityComponent(name: "_id", value: identifier)]),
            fields: [
                DatabaseObjectField(name: "_id", value: identifier),
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

    private static func elasticsearchResponse(
        concurrencyTokens: [DatabaseIdentityComponent]? = nil
    ) -> DatabaseBrokerCommandResponse {
        let record = DatabaseRecord(
            identity: DatabaseRecordIdentity(
                kind: .searchDocument,
                components: [
                    DatabaseIdentityComponent(
                        name: "_index",
                        value: .string("edith-documents-v1")),
                    DatabaseIdentityComponent(name: "_id", value: .string("doc-1")),
                ],
                concurrencyTokens: concurrencyTokens ?? [
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
        .browse(
            .success(
                DatabaseBrowseResult(
                    page: page(records: records, nextContinuation: nextContinuation)),
                metadata: DatabaseResultMetadata(completeness: .init(state: .complete))))
    }

    private static func response(
        records: [DatabaseRecord],
        fields: [DatabaseFieldDescriptor]
    ) -> DatabaseBrokerCommandResponse {
        let completeness = DatabaseResultCompleteness(state: .complete)
        let page = DatabasePage(
            records: records,
            fields: fields,
            metadata: DatabasePageMetadata(
                completeness: completeness,
                count: DatabaseCountMetadata(value: UInt64(records.count), accuracy: .exact)))
        return .browse(
            .success(
                DatabaseBrowseResult(page: page),
                metadata: DatabaseResultMetadata(completeness: completeness)))
    }

    private static func queryResponse(
        records: [DatabaseRecord],
        nextContinuation: DatabaseContinuationToken? = nil
    ) -> DatabaseBrokerCommandResponse {
        .query(
            .success(
                DatabaseQueryResult(
                    page: page(records: records, nextContinuation: nextContinuation)),
                metadata: DatabaseResultMetadata(completeness: .init(state: .complete))))
    }

    private static func page(
        records: [DatabaseRecord],
        nextContinuation: DatabaseContinuationToken?
    ) -> EdithDatabase.DatabasePage<DatabaseRecord> {
        let completeness = DatabaseResultCompleteness(state: .complete)
        return DatabasePage(
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
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("The data workspace did not reach the expected state.")
    }

    private static func waitUntilRequestCount(
        _ expectedCount: Int,
        sender: DatabaseDataControlledSender
    ) async {
        for _ in 0..<10_000 {
            if await sender.requestCount() == expectedCount { return }
            await Task.yield()
        }
        Issue.record("The data workspace did not send the expected request.")
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

private actor DatabaseDataControlledSender: DatabaseBrokerCommandSending {
    private var requests: [DatabaseBrokerCommandRequest] = []
    private var continuations: [CheckedContinuation<DatabaseBrokerCommandResponse, Never>?] = []

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] {
        requests
    }

    func respond(_ response: DatabaseBrokerCommandResponse, to index: Int) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else {
            return
        }
        continuations[index] = nil
        continuation.resume(returning: response)
    }
}

private extension DatabaseBrokerCommandRequest {
    var browseRequest: DatabaseBrowseRequest? {
        guard case .browse(let request) = self else { return nil }
        return request
    }

    var queryRequest: DatabaseQueryRequest? {
        guard case .query(let request) = self else { return nil }
        return request
    }
}

private extension DatabaseValue {
    var objectFields: [DatabaseObjectField]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }
}
