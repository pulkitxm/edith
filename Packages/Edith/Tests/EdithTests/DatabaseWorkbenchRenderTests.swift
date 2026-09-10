import AppKit
@testable import EdithDatabase
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized)
struct DatabaseWorkbenchRenderTests {
    init() {
        _ = TestWindowHost.application
    }

    @Test func populatedWorkbenchRendersAcrossLayoutsAndAppearances() async throws {
        let fixture = try await Self.fixture()

        for width in [CGFloat(1_180), CGFloat(620)] {
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(
                    renderWorkbench(
                        DatabaseWorkbenchView(
                            connections: fixture.connections,
                            explorer: fixture.explorer,
                            tabs: fixture.tabs,
                            mutations: fixture.mutations),
                        width: width,
                        height: 760,
                        scheme: scheme))
                #expect(image.pixelsWide >= Int(width))
                #expect(image.pixelsHigh >= 760)
                #expect(image.representation(using: .png, properties: [:])?.count ?? 0 > 18_000)
            }
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["EDITH_DATABASE_RELATION_FILTERS"] == "1"))
    func relatedFiltersAndTableTabsRenderWithLiveSyntheticData() async throws {
        let definition = try Self.connection()
        let report = Self.capabilityReport()
        let connections = DatabaseConnectionWorkspaceModel(
            sender: DatabaseWorkbenchScriptedSender(responses: [
                Self.connectionListResponse(definition),
                Self.connectionResponse(definition, report: report),
            ]), prepareConnection: { _ in }, announcement: { _ in })
        await connections.loadConnections()
        await connections.connectSelected()
        let connection = try #require(connections.selectedConnection)
        let member = DatabaseObjectIdentifier(kind: .table, path: ["relation_filters", "member"])
        let organization = DatabaseObjectIdentifier(
            kind: .table, path: ["relation_filters", "organization"])
        let enrollment = DatabaseObjectIdentifier(
            kind: .table, path: ["relation_filters", "enrollment"])
        let explorer = DatabaseObjectExplorerModel(
            sender: DatabaseWorkbenchScriptedSender(responses: [
                Self.schemaResponse(name: "relation_filters"),
                Self.browseResponse(
                    DatabasePage(
                        records: [member, organization, enrollment].map { object in
                            DatabaseRecord(fields: [
                                DatabaseObjectField(
                                    name: "name", value: .string(object.path.last!)),
                                DatabaseObjectField(name: "kind", value: .string("table")),
                                DatabaseObjectField(
                                    name: "estimatedRows",
                                    value: .signedInteger(object == member ? 5 : 3)),
                                DatabaseObjectField(name: "columnCount", value: .signedInteger(3)),
                            ])
                        }, metadata: Self.pageMetadata(count: 3))),
            ]))
        explorer.load(connection)
        await Self.waitUntil { explorer.selectedObject != nil }
        explorer.select(member)
        let sender = try await DatabaseWorkbenchLiveFixtureSender.make(definition)
        let tabs = DatabaseTableTabsModel(makeData: {
            DatabaseDataWorkspaceModel(sender: sender, announcement: { _ in })
        })
        tabs.open(member, connection: connection)
        await Self.waitUntil { tabs.data.state == .loaded }
        let memberTab = try #require(tabs.selected)
        tabs.data.addFilterClause(
            field: "organization.slug", operation: .equal, valueText: "sample-studio")
        tabs.data.setSort(field: "id", direction: .descending, additive: false)
        tabs.data.browse(connection)
        await Self.waitUntil { tabs.data.state == .loaded }
        #expect(tabs.data.records.count == 2)
        tabs.open(organization, connection: connection)
        await Self.waitUntil { tabs.data.state == .loaded }
        #expect(tabs.data.filterClauses.isEmpty)
        tabs.open(member, connection: connection)
        #expect(tabs.selected === memberTab)
        #expect(tabs.data.records.count == 2)
        let view = DatabaseWorkbenchView(
            connections: connections, explorer: explorer, tabs: tabs,
            mutations: DatabaseWorkspaceModel())
        for mode in [DatabaseWorkbenchMode.browse, .query] {
            if mode == .query { tabs.data.prepareQuery(member, connection: connection) }
            tabs.selected?.mode = mode
            let directory = ProcessInfo.processInfo.environment["EDITH_DATABASE_EVIDENCE_DIR"]
            let captureURL = directory.map {
                URL(fileURLWithPath: $0).appendingPathComponent("\(mode.rawValue)-window.png")
            }
            let image = try #require(
                renderWorkbench(
                    view, width: 1_180, height: 640, scheme: .dark, captureURL: captureURL))
            if let directory {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true)
                let bytes = try #require(image.representation(using: .png, properties: [:]))
                try bytes.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "\(mode.rawValue).png"))
            }
        }
        #expect(tabs.data.queryText.contains("sample-studio"))
        #expect(tabs.data.queryText.contains("DESC"))
        tabs.open(enrollment, connection: connection)
        explorer.select(enrollment)
        await Self.waitUntil { tabs.data.state == .loaded }
        tabs.data.beginInsert(connection)
        tabs.data.updateEditorField("name", text: "Taylor Demo")
        tabs.data.updateEditorField("role", text: "editor")
        tabs.data.updateEditorField("active", text: "false")
        tabs.data.updateEditorField("settings", text: "{\"notifications\":true}")
        #expect(
            tabs.data.editorFields.first(where: { $0.id == "active" })?.choiceValues == [
                "true", "false",
            ])
        #expect(tabs.data.editorFields.first(where: { $0.id == "id" })?.isGenerated == true)
        #expect(
            tabs.data.editorFields.first(where: { $0.id == "role" })?.enumValues == [
                "viewer", "editor", "admin",
            ])
        let directory = ProcessInfo.processInfo.environment["EDITH_DATABASE_EVIDENCE_DIR"]
        let captureURL = directory.map {
            URL(fileURLWithPath: $0).appendingPathComponent("new-row.png")
        }
        #expect(
            renderWorkbench(view, width: 1_180, height: 640, scheme: .dark, captureURL: captureURL)
                != nil)
        let insert = try #require(tabs.data.editorMutationRequest(connection))
        try await sender.apply(insert)
        tabs.data.finishMutation(connection)
        await Self.waitUntil { tabs.data.state == .loaded }
        let inserted = try #require(
            tabs.data.records.first(where: { record in
                record.fields.contains { $0.name == "name" && $0.value == .string("Taylor Demo") }
            }))
        let insertedIdentity = try #require(inserted.identity)
        let insertedIndex = try #require(tabs.data.records.firstIndex(of: inserted))
        tabs.data.selectRecord(at: insertedIndex)
        tabs.data.beginEditingSelectedRow(connection)
        tabs.data.updateEditorField("role", text: "admin")
        let update = try #require(tabs.data.editorMutationRequest(connection))
        try await sender.apply(update)
        tabs.data.finishMutation(connection)
        await Self.waitUntil { tabs.data.state == .loaded }
        let savedURL = directory.map {
            URL(fileURLWithPath: $0).appendingPathComponent("saved-row.png")
        }
        #expect(
            renderWorkbench(view, width: 1_180, height: 640, scheme: .dark, captureURL: savedURL)
                != nil)
        try await sender.apply(
            DatabaseRowMutationRequests.postgreSQLDelete(
                target: DatabaseTargetIdentifier(
                    connectionID: definition.id, object: enrollment,
                    record: insertedIdentity)))
        await sender.disconnect()
    }

    private static func fixture() async throws -> DatabaseWorkbenchRenderFixture {
        let definition = try connection()
        let report = capabilityReport()
        let connectionSender = DatabaseWorkbenchScriptedSender(responses: [
            connectionListResponse(definition),
            connectionResponse(definition, report: report),
        ])
        let connections = DatabaseConnectionWorkspaceModel(
            sender: connectionSender,
            currentDate: { Date(timeIntervalSince1970: 8_000) },
            prepareConnection: { _ in },
            announcement: { _ in })
        await connections.loadConnections()
        await connections.connectSelected()
        let connection = try #require(connections.selectedConnection)

        let explorerSender = DatabaseWorkbenchScriptedSender(responses: [
            schemaResponse(),
            objectResponse(),
        ])
        let explorer = DatabaseObjectExplorerModel(sender: explorerSender)
        explorer.load(connection)
        await waitUntil { explorer.selectedObject != nil }
        let object = try #require(explorer.selectedObject)

        let dataSender = DatabaseWorkbenchScriptedSender(responses: [dataResponse()])
        let data = DatabaseDataWorkspaceModel(sender: dataSender, announcement: { _ in })
        data.prepare(for: connection)
        data.open(object, connection: connection)
        await waitUntil { data.state == .loaded }
        data.addFilterClause(field: "status", operation: .equal, valueText: "active")
        data.addFilterClause(field: "customer", operation: .contains, valueText: "a")
        data.setSort(field: "created_at", direction: .descending, additive: false)
        data.setSort(field: "id", direction: .ascending, additive: true)
        data.selectRecord(at: 1)

        let tabs = DatabaseTableTabsModel(data: data)
        tabs.prepare(for: connection)
        tabs.open(object, connection: connection)
        return DatabaseWorkbenchRenderFixture(
            connections: connections,
            explorer: explorer,
            tabs: tabs,
            mutations: DatabaseWorkspaceModel())
    }

    private static func connection() throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: DatabaseConnectionID(
                rawValue: UUID(uuidString: "7B91F479-A32B-40E0-94D5-037644F5DB10")!),
            displayName: "Orders warehouse",
            productHint: .postgresql,
            location: .network([
                DatabaseNetworkEndpoint(host: "warehouse.internal", port: try DatabasePort(5_432))
            ]),
            username: "operator",
            namespaces: DatabaseNamespaceDefaults(schema: "public", database: "commerce"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(kind: .usernameAndPassword),
            tls: DatabaseTLSConfiguration(mode: .required, verification: .full),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            readOnlyPolicy: .disabled,
            productionPolicy: .requireMutationPreview,
            environment: DatabaseEnvironmentMetadata(
                kind: .development,
                label: "development",
                protection: .standard),
            group: "commerce",
            tags: ["orders", "primary"],
            color: "indigo",
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastUsedAt: Date(timeIntervalSince1970: 3_000))
    }

    private static func capabilityReport() -> DatabaseCapabilityReport {
        let capabilities: [DatabaseCapabilityID] = [.browse, .insert, .update, .delete]
        return DatabaseCapabilityReport(
            productIdentity: DatabaseProductIdentity(
                product: .postgresql,
                version: DatabaseVersion(string: "17.4"),
                topology: DatabaseTopology(kind: .standalone)),
            capabilities: capabilities.map {
                DatabaseCapabilityStatus(
                    id: $0,
                    requirement: .sharedRequired,
                    availability: .available)
            },
            pagingModes: [.keyset],
            cancellationModes: [.protocolCancellation],
            discoveredAt: Date(timeIntervalSince1970: 8_000),
            expiresAt: Date(timeIntervalSince1970: 8_300))
    }

    private static func connectionListResponse(
        _ connection: DatabaseConnectionDefinition
    ) -> DatabaseBrokerCommandResponse {
        .connectionList(
            .success(
                DatabaseConnectionListResult(connections: [connection]),
                metadata: completeMetadata))
    }

    private static func connectionResponse(
        _ connection: DatabaseConnectionDefinition,
        report: DatabaseCapabilityReport
    ) -> DatabaseBrokerCommandResponse {
        .connect(
            .success(
                DatabaseConnectResult(
                    connection: connection.identity,
                    productIdentity: report.productIdentity,
                    capabilities: report,
                    connectedAt: Date(timeIntervalSince1970: 8_000)),
                metadata: completeMetadata))
    }

    private static func schemaResponse(name: String = "public") -> DatabaseBrokerCommandResponse {
        let page = DatabasePage(
            records: [
                DatabaseRecord(fields: [
                    DatabaseObjectField(name: "name", value: .string(name)),
                    DatabaseObjectField(name: "canUse", value: .boolean(true)),
                ])
            ],
            fields: [],
            metadata: pageMetadata(count: 1))
        return browseResponse(page)
    }

    private static func objectResponse() -> DatabaseBrokerCommandResponse {
        let page = DatabasePage(
            records: [
                DatabaseRecord(fields: [
                    DatabaseObjectField(name: "name", value: .string("orders")),
                    DatabaseObjectField(name: "kind", value: .string("table")),
                    DatabaseObjectField(name: "estimatedRows", value: .signedInteger(12_480)),
                    DatabaseObjectField(name: "columnCount", value: .signedInteger(7)),
                ]),
                DatabaseRecord(fields: [
                    DatabaseObjectField(name: "name", value: .string("customers")),
                    DatabaseObjectField(name: "kind", value: .string("table")),
                    DatabaseObjectField(name: "estimatedRows", value: .signedInteger(3_842)),
                    DatabaseObjectField(name: "columnCount", value: .signedInteger(6)),
                ]),
                DatabaseRecord(fields: [
                    DatabaseObjectField(name: "name", value: .string("daily_revenue")),
                    DatabaseObjectField(name: "kind", value: .string("view")),
                    DatabaseObjectField(name: "columnCount", value: .signedInteger(5)),
                ]),
            ],
            fields: [],
            metadata: pageMetadata(count: 3))
        return browseResponse(page)
    }

    private static func dataResponse() -> DatabaseBrokerCommandResponse {
        let names = [
            "Ada Lovelace", "Grace Hopper", "Margaret Hamilton", "Barbara Liskov",
            "Radia Perlman", "Annie Easley", "Mary Jackson", "Karen Spärck Jones",
            "Frances Allen", "Evelyn Boyd Granville", "Jean Sammet", "Adele Goldberg",
        ]
        let records = names.enumerated().map { index, name in
            let identifier = Int64(1_024 + index)
            let day = String(format: "%02d", 18 + index)
            return DatabaseRecord(
                identity: DatabaseRecordIdentity(
                    kind: .primaryKey,
                    components: [
                        DatabaseIdentityComponent(name: "id", value: .signedInteger(identifier))
                    ]),
                fields: [
                    DatabaseObjectField(name: "id", value: .signedInteger(identifier)),
                    DatabaseObjectField(name: "customer", value: .string(name)),
                    DatabaseObjectField(
                        name: "email",
                        value: .string(
                            name.lowercased().replacingOccurrences(of: " ", with: ".")
                                + "@example.com")),
                    DatabaseObjectField(
                        name: "status",
                        value: .string(index.isMultiple(of: 4) ? "review" : "active")),
                    DatabaseObjectField(
                        name: "total",
                        value: .string("$\(128 + index * 37).00")),
                    DatabaseObjectField(
                        name: "created_at",
                        value: .timestamp(
                            DatabaseTimestampValue(text: "2026-08-\(day)T09:42:00Z"))),
                ])
        }
        let fields = [
            field("id", type: "bigint", nullable: false),
            field("customer", type: "text", nullable: false),
            field("email", type: "text", nullable: false),
            field("status", type: "text", nullable: false),
            field("total", type: "numeric", nullable: false),
            field("created_at", type: "timestamp", nullable: false),
        ]
        return browseResponse(
            DatabasePage(
                records: records,
                fields: fields,
                metadata: DatabasePageMetadata(
                    completeness: DatabaseResultCompleteness(state: .sampled),
                    count: DatabaseCountMetadata(value: 12_480, accuracy: .estimated))))
    }

    private static func field(
        _ name: String,
        type: String,
        nullable: Bool
    ) -> DatabaseFieldDescriptor {
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath(name),
            displayName: name,
            typeName: type,
            isNullable: nullable,
            isSortable: true,
            isFilterable: true)
    }

    private static func browseResponse(
        _ page: EdithDatabase.DatabasePage<DatabaseRecord>
    ) -> DatabaseBrokerCommandResponse {
        .browse(
            .success(
                DatabaseBrowseResult(page: page),
                metadata: DatabaseResultMetadata(completeness: page.metadata.completeness)))
    }

    private static func pageMetadata(count: UInt64) -> DatabasePageMetadata {
        DatabasePageMetadata(
            completeness: DatabaseResultCompleteness(state: .complete),
            count: DatabaseCountMetadata(value: count, accuracy: .exact))
    }

    private static let completeMetadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("The workbench fixture did not reach the expected state.")
    }
}

@MainActor
private struct DatabaseWorkbenchRenderFixture {
    let connections: DatabaseConnectionWorkspaceModel
    let explorer: DatabaseObjectExplorerModel
    let tabs: DatabaseTableTabsModel
    let mutations: DatabaseWorkspaceModel
}

private actor DatabaseWorkbenchScriptedSender: DatabaseBrokerCommandSending {
    private var responses: [DatabaseBrokerCommandResponse]

    init(responses: [DatabaseBrokerCommandResponse]) {
        self.responses = responses
    }

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        guard !responses.isEmpty else {
            throw DatabaseBrokerCommandClientError.invalidRequest
        }
        return responses.removeFirst()
    }
}

@MainActor
private func renderWorkbench(
    _ view: some View,
    width: CGFloat,
    height: CGFloat,
    scheme: ColorScheme,
    captureURL: URL? = nil
) -> NSBitmapImageRep? {
    let host = NSHostingView(
        rootView:
            view
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.compactLayout, width < 680)
            .preferredColorScheme(scheme))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = TestWindowHost.window(contentRect: host.frame)
    defer { window.orderOut(nil) }
    window.appearance = NSAppearance(
        named: scheme == .dark ? .darkAqua : .aqua)
    window.backgroundColor = .windowBackgroundColor
    window.contentView = host
    window.orderBack(nil)
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    func redraw(_ view: NSView) {
        for child in view.subviews { redraw(child) }
        view.needsDisplay = true
        view.displayIfNeeded()
    }
    redraw(host)
    if let captureURL {
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        window.orderFrontRegardless()
        window.display()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), captureURL.path]
        do {
            try FileManager.default.createDirectory(
                at: captureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try capture.run()
            capture.waitUntilExit()
            if capture.terminationStatus == 0, let bytes = try? Data(contentsOf: captureURL) {
                return NSBitmapImageRep(data: bytes)
            }
        } catch {
            Issue.record("Unable to capture the synthetic database window: \(error)")
        }
        return nil
    }
    guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: image)
    return image
}

private actor DatabaseWorkbenchLiveFixtureSender: DatabaseBrokerCommandSending {
    let session: PostgreSQLDatabaseAdapterSession

    init(session: PostgreSQLDatabaseAdapterSession) {
        self.session = session
    }

    static func make(_ definition: DatabaseConnectionDefinition) async throws
        -> DatabaseWorkbenchLiveFixtureSender
    {
        let values = ProcessInfo.processInfo.environment
        let database = try #require(values["EDITH_DATABASE_POSTGRESQL_DATABASE"])
        let client = try await PostgresNIODatabaseClient.connect(
            PostgreSQLDatabaseConnectionPlan(
                host: try #require(values["EDITH_DATABASE_POSTGRESQL_HOST"]),
                port: try #require(Int(values["EDITH_DATABASE_POSTGRESQL_PORT"] ?? "")),
                username: try #require(values["EDITH_DATABASE_POSTGRESQL_USERNAME"]),
                password: values["EDITH_DATABASE_POSTGRESQL_PASSWORD"],
                database: database,
                tls: .disabled, tlsServerName: nil,
                connectTimeoutMilliseconds: 5_000, statementTimeoutMilliseconds: 15_000,
                readOnly: false))
        let identity = try await client.discoverIdentity()
        return DatabaseWorkbenchLiveFixtureSender(
            session: PostgreSQLDatabaseAdapterSession(
                connection: definition, productIdentity: identity, client: client))
    }

    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        guard case .browse(let request) = request else {
            throw DatabaseBrokerCommandClientError.invalidRequest
        }
        let page = try await session.readPage(
            DatabaseAdapterPageRequest(
                target: request.target, page: request.page, continuation: nil),
            context: DatabaseAdapterOperationContext(
                operation: DatabaseOperationContext(),
                cancellation: DatabaseAdapterCancellationSignal()))
        return .browse(
            .success(
                DatabaseBrowseResult(
                    page: DatabasePage(
                        records: page.records, fields: page.fields, metadata: page.metadata)),
                metadata: DatabaseResultMetadata(completeness: .init(state: .complete))))
    }

    func apply(_ request: DatabaseDestructiveRequest) async throws {
        let context = DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(), cancellation: DatabaseAdapterCancellationSignal()
        )
        let plan = try await session.normalizeMutation(request, context: context)
        let result = try await session.executeMutation(plan, context: context)
        #expect(result.effect == .applied)
        #expect(result.affectedRecords.value == 1)
    }

    func disconnect() async { await session.disconnect() }
}
