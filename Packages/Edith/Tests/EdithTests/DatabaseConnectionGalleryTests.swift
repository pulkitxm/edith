import AppKit
import EdithDatabase
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized)
struct DatabaseConnectionGalleryTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func selectedFirstConnectionStillRendersInCatalog() async throws {
        let fixture = try await Self.fixture()

        #expect(fixture.model.selectedConnectionID == fixture.connections[0].id)
        #expect(
            galleryRenders(
                DatabaseConnectionGallery(
                    model: fixture.model,
                    createConnection: {},
                    openConnection: { _ in }
                )
                .preferredColorScheme(.light),
                width: 1_024,
                height: 700))
        #expect(await fixture.sender.requestCount == 1)
    }

    @Test func cardActivationOpensWithoutConnecting() async throws {
        let fixture = try await Self.fixture()
        var openedConnectionID: DatabaseConnectionID?
        let openConnection: (DatabaseConnectionSummary) -> Void = { connection in
            fixture.model.selectConnection(connection.id)
            openedConnectionID = connection.id
        }
        let view = DatabaseConnectionGallery(
            model: fixture.model,
            createConnection: {},
            openConnection: openConnection)

        withGalleryHost(view, width: 1_024, height: 700) { host in
            let cardTargets =
                galleryDescendantViews(of: host)
                .filter { view in
                    String(describing: type(of: view)).contains("KeyViewProxy")
                        && view.frame.width > 250
                }
            #expect(cardTargets.count == fixture.connections.count)
        }
        let reporting = try #require(fixture.model.visibleConnections.last)
        openConnection(reporting)

        #expect(openedConnectionID == fixture.connections[1].id)
        #expect(fixture.model.selectedConnectionID == fixture.connections[1].id)
        #expect(fixture.model.selectedSessionState == .disconnected)
        #expect(await fixture.sender.requestCount == 1)
    }

    @Test func galleryRendersWideAndCompactInBothAppearances() async throws {
        let fixture = try await Self.fixture()

        for width in [CGFloat(1_024), CGFloat(560)] {
            #expect(
                galleryRenders(
                    DatabaseConnectionGallery(
                        model: fixture.model,
                        createConnection: {},
                        openConnection: { _ in }
                    )
                    .preferredColorScheme(.light),
                    width: width,
                    height: 700),
                "light gallery failed at \(Int(width)) points")
            #expect(
                galleryRenders(
                    DatabaseConnectionGallery(
                        model: fixture.model,
                        createConnection: {},
                        openConnection: { _ in }
                    )
                    .preferredColorScheme(.dark),
                    width: width,
                    height: 700),
                "dark gallery failed at \(Int(width)) points")
        }
    }

    @Test func focusedHeaderKeepsBackPathAndConnectionContext() async throws {
        let fixture = try await Self.fixture()
        fixture.model.selectConnection(fixture.connections[1].id)
        let connection = try #require(fixture.model.selectedConnection)
        var returnedToCatalog = false
        let back = { returnedToCatalog = true }
        let view = DatabaseFocusedConnectionHeader(
            connection: connection,
            sessionState: fixture.model.selectedSessionState,
            backDisabled: false,
            back: back)

        withGalleryHost(view, width: 1_024, height: 90) { host in
            let descendants = galleryDescendantViews(of: host)
            let navigationTargets = descendants.filter { view in
                String(describing: type(of: view)).contains("KeyViewProxy")
            }

            #expect(connection.name == "Reporting cache")
            #expect(connection.product == .redis)
            #expect(connection.environmentKind == .testing)
            #expect(connection.readOnlySummary == "Read-only preferred")
            #expect(navigationTargets.count == 1)
        }
        back()

        #expect(returnedToCatalog)
        #expect(fixture.model.selectedSessionState == .disconnected)
        #expect(await fixture.sender.requestCount == 1)
    }

    @Test func focusedHeaderRendersWideAndCompactInBothAppearances() async throws {
        let fixture = try await Self.fixture()
        let connection = try #require(fixture.model.selectedConnection)

        for width in [CGFloat(1_024), CGFloat(560)] {
            #expect(
                galleryRenders(
                    DatabaseFocusedConnectionHeader(
                        connection: connection,
                        sessionState: .disconnected,
                        backDisabled: false,
                        back: {}
                    )
                    .preferredColorScheme(.light),
                    width: width,
                    height: width < 680 ? 116 : 90),
                "light focused header failed at \(Int(width)) points")
            #expect(
                galleryRenders(
                    DatabaseFocusedConnectionHeader(
                        connection: connection,
                        sessionState: .disconnected,
                        backDisabled: false,
                        back: {}
                    )
                    .preferredColorScheme(.dark),
                    width: width,
                    height: width < 680 ? 116 : 90),
                "dark focused header failed at \(Int(width)) points")
        }
    }

    private static func fixture() async throws -> DatabaseConnectionGalleryFixture {
        let connections = [
            try connection(
                id: 1,
                displayName: "Primary warehouse",
                product: .postgresql,
                environmentKind: .production,
                readOnlyPolicy: .required,
                isFavorite: true),
            try connection(
                id: 2,
                displayName: "Reporting cache",
                product: .redis,
                environmentKind: .testing,
                readOnlyPolicy: .preferred,
                isFavorite: false),
        ]
        let sender = DatabaseGallerySender(connections: connections)
        let model = DatabaseConnectionWorkspaceModel(
            sender: sender,
            currentDate: { Date(timeIntervalSince1970: 8_000) },
            prepareConnection: { _ in },
            announcement: { _ in })
        await model.loadConnections()
        return DatabaseConnectionGalleryFixture(
            model: model,
            sender: sender,
            connections: connections)
    }

    private static func connection(
        id: UInt8,
        displayName: String,
        product: DatabaseProduct,
        environmentKind: DatabaseEnvironmentKind,
        readOnlyPolicy: DatabaseReadOnlyPolicy,
        isFavorite: Bool
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: DatabaseConnectionID(rawValue: uuid(id)),
            displayName: displayName,
            productHint: product,
            location: .network([
                DatabaseNetworkEndpoint(host: "database.internal", port: try DatabasePort(5_432))
            ]),
            username: "reader",
            namespaces: DatabaseNamespaceDefaults(schema: "public", database: "workspace"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(kind: .usernameAndPassword),
            tls: DatabaseTLSConfiguration(mode: .required, verification: .full),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            readOnlyPolicy: readOnlyPolicy,
            productionPolicy: .requireMutationPreview,
            environment: DatabaseEnvironmentMetadata(
                kind: environmentKind,
                label: environmentKind.title,
                protection: .confirmationRequired),
            group: "workspace",
            tags: ["test"],
            isFavorite: isFavorite,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastUsedAt: Date(timeIntervalSince1970: 3_000))
    }

    private static func uuid(_ value: UInt8) -> UUID {
        UUID(
            uuid: (
                0x65, 0x20, 0x9A, 0xB4, 0x61, 0x99, 0x4D, 0x1B,
                0x90, 0x02, 0x43, 0x08, 0x77, 0x00, 0x00, value
            ))
    }
}

@MainActor
private struct DatabaseConnectionGalleryFixture {
    let model: DatabaseConnectionWorkspaceModel
    let sender: DatabaseGallerySender
    let connections: [DatabaseConnectionDefinition]
}

private actor DatabaseGallerySender: DatabaseBrokerCommandSending {
    private let response: DatabaseBrokerCommandResponse
    private(set) var requestCount = 0

    init(connections: [DatabaseConnectionDefinition]) {
        let payload = DatabaseConnectionListResult(connections: connections)
        let metadata = DatabaseResultMetadata(
            completeness: DatabaseResultCompleteness(state: .complete))
        response = .connectionList(.success(payload, metadata: metadata))
    }

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        requestCount += 1
        return response
    }
}

@MainActor
private func galleryRenders(
    _ view: some View,
    width: CGFloat,
    height: CGFloat
) -> Bool {
    withGalleryHost(view, width: width, height: height) { host in
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return false
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0
    }
}

@MainActor
private func withGalleryHost<Content: View, Result>(
    _ view: Content,
    width: CGFloat,
    height: CGFloat,
    body: (NSView) throws -> Result
) rethrows -> Result {
    let host = NSHostingView(
        rootView:
            view
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.compactLayout, width < 680))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
    defer { window.orderOut(nil) }
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    return try body(host)
}

@MainActor
private func galleryDescendantViews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { galleryDescendantViews(of: $0) }
}
