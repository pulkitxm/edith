import AppKit
import EdithDatabase
import EdithKit
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

    @Test func compactCardsKeepOpenRoutingSeparateFromConnection() async throws {
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
            let cardRegions = galleryKeyRegions(of: host) { frame in
                frame.width > 250 && frame.width < 400 && frame.height > 110
                    && frame.height < 180
            }
            #expect(cardRegions.count == fixture.connections.count)
        }
        let reporting = try #require(fixture.model.visibleConnections.last)
        openConnection(reporting)

        #expect(openedConnectionID == fixture.connections[1].id)
        #expect(fixture.model.selectedConnectionID == fixture.connections[1].id)
        #expect(fixture.model.selectedSessionState == .disconnected)
        #expect(await fixture.sender.requestCount == 1)
    }

    @Test func focusRestorationKeepsTheOpenedCardAndRejectsMissingCards() async throws {
        let fixture = try await Self.fixture()
        let restored = fixture.connections[1]
        let missing = DatabaseConnectionID(
            rawValue: try #require(
                UUID(uuidString: "65209AB4-6199-4D1B-9002-430877000099")))
        let visibleConnectionIDs = fixture.model.visibleConnections.map(\.id)
        await fixture.sender.gateNextRequest()
        let view = DatabaseConnectionGalleryFocusHarness(
            model: fixture.model,
            restoreFocusConnectionID: restored.id)

        await withGalleryHostAsync(view, width: 1_024, height: 700) { host in
            let cardRegions = galleryKeyRegions(of: host) { frame in
                frame.width > 250 && frame.width < 400 && frame.height > 110
                    && frame.height < 180
            }
            let restoredRegion = cardRegions.max { $0.x < $1.x }
            #expect(galleryResponderRegion(of: host) == restoredRegion)

            let searchField = galleryDescendantViews(of: host).first { view in
                let frame = view.convert(view.bounds, to: host)
                return view.acceptsFirstResponder && frame.width > 400 && frame.height < 40
            }
            #expect(host.window?.makeFirstResponder(searchField) == true)
            let searchResponder = host.window?.firstResponder
            let reload = Task { @MainActor in await fixture.model.loadConnections() }
            await fixture.sender.waitUntilRequested(2)
            let isLoading: Bool
            if case .loading = fixture.model.listState {
                isLoading = true
            } else {
                isLoading = false
            }
            #expect(isLoading)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            #expect(host.window?.firstResponder === searchResponder)
            await fixture.sender.releaseRequest()
            await reload.value

        }

        #expect(
            DatabaseConnectionGalleryFocusRequest(
                requestedConnectionID: restored.id,
                visibleConnectionIDs: visibleConnectionIDs
            ).target == restored.id)
        #expect(
            DatabaseConnectionGalleryFocusRequest(
                requestedConnectionID: missing,
                visibleConnectionIDs: visibleConnectionIDs
            ).target == nil)
    }

    @Test func cardSecondaryTextMeetsNormalTextContrastAcrossThemes() {
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let palette = DatabaseThemePalette(dark: dark, theme: theme)
                let card = blended(palette.panel, over: palette.canvas, opacity: 0.74)
                #expect(
                    contrastRatio(palette.inkSoft, card) >= 4.5,
                    "secondary text contrast failed for \(theme.rawValue) in \(dark ? "dark" : "light") mode"
                )
            }
        }
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
        var focusCompleted = false
        let back = { returnedToCatalog = true }
        let view = DatabaseFocusedConnectionHeader(
            connection: connection,
            sessionState: fixture.model.selectedSessionState,
            backDisabled: false,
            focusRequested: true,
            focusCompleted: { focusCompleted = true },
            back: back)

        await withGalleryHostAsync(view, width: 1_024, height: 90) { host in
            let navigationRegions = galleryKeyRegions(of: host) { frame in
                frame.width > 80 && frame.width < 240 && frame.height > 20 && frame.height < 60
            }

            #expect(connection.name == "Reporting cache")
            #expect(connection.product == .redis)
            #expect(connection.environmentKind == .testing)
            #expect(connection.readOnlySummary == "Read-only preferred")
            #expect(navigationRegions.count == 1)
            #expect(galleryResponderRegion(of: host) == navigationRegions.first)
        }
        back()

        #expect(returnedToCatalog)
        #expect(focusCompleted)
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
                        focusRequested: false,
                        focusCompleted: {},
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
                        focusRequested: false,
                        focusCompleted: {},
                        back: {}
                    )
                    .preferredColorScheme(.dark),
                    width: width,
                    height: width < 680 ? 116 : 90),
                "dark focused header failed at \(Int(width)) points")
        }
    }

    @Test func managementMenusRenderAcrossCatalogAndFocusedWorkspace() async throws {
        let fixture = try await Self.fixture()
        let connection = try #require(fixture.model.selectedConnection)
        let perform: (DatabaseConnectionCardAction, DatabaseConnectionSummary) -> Void = { _, _ in }

        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            #expect(
                galleryRenders(
                    DatabaseConnectionGallery(
                        model: fixture.model,
                        createConnection: {},
                        openConnection: { _ in },
                        busyConnectionID: connection.id,
                        performConnectionAction: perform
                    )
                    .environment(\.databaseAppTheme, .purple)
                    .preferredColorScheme(scheme),
                    width: 1_024,
                    height: 700),
                "management gallery failed in \(dark ? "dark" : "light") mode")
            #expect(
                galleryRenders(
                    DatabaseFocusedConnectionHeader(
                        connection: connection,
                        sessionState: .disconnected,
                        backDisabled: false,
                        focusRequested: false,
                        focusCompleted: {},
                        back: {},
                        busyConnectionID: connection.id,
                        performConnectionAction: perform
                    )
                    .environment(\.databaseAppTheme, .purple)
                    .preferredColorScheme(scheme),
                    width: 1_024,
                    height: 90),
                "management header failed in \(dark ? "dark" : "light") mode")
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

@MainActor
private struct DatabaseConnectionGalleryFocusHarness: View {
    @Bindable var model: DatabaseConnectionWorkspaceModel
    @State private var restoreFocusConnectionID: DatabaseConnectionID?

    init(
        model: DatabaseConnectionWorkspaceModel,
        restoreFocusConnectionID: DatabaseConnectionID
    ) {
        self.model = model
        _restoreFocusConnectionID = State(initialValue: restoreFocusConnectionID)
    }

    var body: some View {
        DatabaseConnectionGallery(
            model: model,
            createConnection: {},
            openConnection: { _ in },
            restoreFocusConnectionID: restoreFocusConnectionID,
            focusRestored: { connectionID in
                guard restoreFocusConnectionID == connectionID else { return }
                restoreFocusConnectionID = nil
            })
    }
}

private actor DatabaseGallerySender: DatabaseBrokerCommandSending {
    private let response: DatabaseBrokerCommandResponse
    private(set) var requestCount = 0
    private var gateNext = false
    private var requestContinuation: CheckedContinuation<Void, Never>?

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
        if gateNext {
            gateNext = false
            await withCheckedContinuation { continuation in
                requestContinuation = continuation
            }
        }
        return response
    }

    func gateNextRequest() {
        gateNext = true
    }

    func waitUntilRequested(_ count: Int) async {
        while requestCount < count {
            await Task.yield()
        }
    }

    func releaseRequest() {
        requestContinuation?.resume()
        requestContinuation = nil
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
        let png = bitmap.representation(using: .png, properties: [:])
        return bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && (png?.count ?? 0) > 8_000
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
    let window = DatabaseConnectionGalleryTestWindow(
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
private func withGalleryHostAsync<Content: View, Result>(
    _ view: Content,
    width: CGFloat,
    height: CGFloat,
    body: (NSView) async throws -> Result
) async rethrows -> Result {
    let host = NSHostingView(
        rootView:
            view
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.compactLayout, width < 680))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = DatabaseConnectionGalleryTestWindow(
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
    try? await Task.sleep(for: .milliseconds(50))
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    return try await body(host)
}

@MainActor
private func galleryDescendantViews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { galleryDescendantViews(of: $0) }
}

private final class DatabaseConnectionGalleryTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct GalleryViewRegion: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ frame: NSRect) {
        x = Int((frame.minX * 2).rounded())
        y = Int((frame.minY * 2).rounded())
        width = Int((frame.width * 2).rounded())
        height = Int((frame.height * 2).rounded())
    }
}

@MainActor
private func galleryKeyRegions(
    of host: NSView,
    matching predicate: (NSRect) -> Bool
) -> Set<GalleryViewRegion> {
    host.window?.recalculateKeyViewLoop()
    return Set(
        galleryDescendantViews(of: host).compactMap { view in
            guard view.nextKeyView != nil || view.previousKeyView != nil else { return nil }
            let frame = view.convert(view.bounds, to: host)
            guard predicate(frame) else { return nil }
            return GalleryViewRegion(frame)
        })
}

@MainActor
private func galleryResponderRegion(of host: NSView) -> GalleryViewRegion? {
    guard let view = host.window?.firstResponder as? NSView else { return nil }
    return GalleryViewRegion(view.convert(view.bounds, to: host))
}

private func blended(_ foreground: Color, over background: Color, opacity: Double) -> Color {
    let foreground = colorComponents(foreground)
    let background = colorComponents(background)
    return Color(
        red: foreground.red * opacity + background.red * (1 - opacity),
        green: foreground.green * opacity + background.green * (1 - opacity),
        blue: foreground.blue * opacity + background.blue * (1 - opacity))
}

private func contrastRatio(_ first: Color, _ second: Color) -> Double {
    let firstLuminance = relativeLuminance(first)
    let secondLuminance = relativeLuminance(second)
    return (max(firstLuminance, secondLuminance) + 0.05)
        / (min(firstLuminance, secondLuminance) + 0.05)
}

private func relativeLuminance(_ color: Color) -> Double {
    let components = colorComponents(color)
    return 0.2126 * linearized(components.red) + 0.7152 * linearized(components.green)
        + 0.0722 * linearized(components.blue)
}

private func linearized(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}

private func colorComponents(_ color: Color) -> (red: Double, green: Double, blue: Double) {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
    return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
}
