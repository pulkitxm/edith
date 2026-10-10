import AppKit
import CryptoKit
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostSuiteLandingTests {
    @Test func deskKeepsTheOriginalGroupsAndEveryOptionalAbility() throws {
        let entries = try HostIndex.bundled().filter { $0.category == "desk" }
        let groups = HostSuiteLandingGroups.groups(suite: "desk", entries: entries)
        #expect(groups.map(\.title) == ["Launcher", "Pickers", "Stage"])
        #expect(groups[0].entries.map(\.id) == ["bifrost"])
        #expect(Set(groups[1].entries.map(\.id)) == ["clipboard", "emoji", "colorPicker"])
        #expect(Set(groups.flatMap(\.entries).map(\.id)) == Set(entries.map(\.id)))
        #expect(groups.flatMap(\.entries).count == entries.count)
    }

    @Test func otherSuitesRetainDownloadedDisabledAndUndownloadedRows() throws {
        let entries = try HostIndex.bundled()
        for suite in HostMarketplaceCatalog.suites {
            let members = entries.filter { $0.category == suite.id }
            let groups = HostSuiteLandingGroups.groups(suite: suite.id, entries: members)
            #expect(groups.flatMap(\.entries).map(\.id) == members.map(\.id) || suite.id == "desk")
        }
    }

    @Test func activeDatabaseOpensItsExistingPageAndNeverRequestsSettings() throws {
        let entry = try entry("database")
        var pages: [String] = [], details: [String] = []
        HostExtensionActions.open(
            entry, active: true, openPage: { pages.append($0) },
            showDetails: { details.append($0.id) })
        #expect(pages == ["database"])
        #expect(details.isEmpty)
        #expect(HostNavigationCatalog.route(extensionID: "database")?.page == "database")
        #expect(!HostExtensionSettingsPolicy.canPresent(id: "database", active: true))
        #expect(!HostExtensionSettingsPolicy.canPresent(id: "database", active: false))
    }

    @Test func maintenanceNavigationPreservesItsOriginalChildAndHelpersUseReview() throws {
        let route = try #require(HostNavigationCatalog.route(extensionID: "homebrew"))
        #expect(route.page == "appMaintenance" && route.section == "Packages")
        var pages: [String] = [], details: [String] = []
        HostExtensionActions.open(
            try entry("homebrew"), active: true, openPage: { pages.append($0) },
            showDetails: { details.append($0.id) })
        HostExtensionActions.open(
            try entry("emoji"), active: true, openPage: { pages.append($0) },
            showDetails: { details.append($0.id) })
        HostExtensionActions.open(
            try entry("database"), active: false, openPage: { pages.append($0) },
            showDetails: { details.append($0.id) })
        #expect(pages == ["homebrew"])
        #expect(details == ["emoji", "database"])
    }

    @Test func settingsAdmissionMatchesExplicitPreferencesAndActiveOnlyContracts() {
        #expect(HostExtensionSettingsPolicy.canPresent(id: "emoji", active: false))
        #expect(HostExtensionSettingsPolicy.canPresent(id: "keepAwake", active: false))
        #expect(HostExtensionSettingsPolicy.canPresent(id: "downloads", active: true))
        #expect(!HostExtensionSettingsPolicy.canPresent(id: "downloads", active: false))
        for id in ["calendar", "terminal", "database", "docs", "studio", "machines", "unknown"] {
            #expect(!HostExtensionSettingsPolicy.canPresent(id: id, active: true))
            #expect(!HostExtensionSettingsPolicy.canPresent(id: id, active: false))
        }
    }

    @Test func originalRowsRenderCompactRegularZoomAndBothSchemesWithoutOrderingWindows()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        let destination = try #require(HostNavigationCatalog.pages.first { $0.id == "desk" })
        var images = Set<Data>()
        for (width, zoom, scheme) in [
            (1000.0, 1.0, ColorScheme.light), (1000.0, 1.0, ColorScheme.dark),
            (520.0, 1.0, ColorScheme.light), (520.0, 1.0, ColorScheme.dark),
            (700.0, 1.5, ColorScheme.light), (700.0, 1.5, ColorScheme.dark),
        ] {
            UIScale.apply(zoom)
            let host = NSHostingView(
                rootView: HostSuiteLandingPage(
                    marketplace: fixture.marketplace, destination: destination,
                    openExtension: { _ in Issue.record("Rendering cannot navigate") }
                )
                .environment(\.compactLayout, width < UIScale.pt(720))
                .environment(\.colorScheme, scheme)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.windowVisible, false)
                .transaction { $0.animation = nil })
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            defer { window.close() }
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded(); window.layoutIfNeeded()
                await Task.yield()
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            #expect(bitmap.pixelsWide >= Int(width))
            #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
            #expect(!window.isVisible && !window.isKeyWindow)
            #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
            images.insert(png)
        }
        #expect(images.count == 6)
    }

    private func entry(_ id: String) throws -> HostExtension {
        try #require(HostIndex.bundled().first { $0.id == id })
    }

    @MainActor private struct Fixture {
        let root: URL
        let marketplace: HostMarketplace

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.suite-" + UUID().uuidString,
                supportDirectory: root)
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            let installed = ["emoji", "focusDim"].map {
                ExtensionPackage(
                    id: $0, version: "1.0.0", hostABI: HostContract.compatibility,
                    downloadURL: URL(string: "https://example.invalid/\($0).zip")!,
                    sha256: String(repeating: "a", count: 64), downloadBytes: 100,
                    installedBytes: 200)
            }
            for package in installed {
                try FileManager.default.createDirectory(
                    at: store.directory(for: package), withIntermediateDirectories: true)
            }
            try store.commit(installed)
            marketplace = try HostMarketplace(
                identity: identity, entries: HostIndex.bundled(), store: store,
                catalogClient: ExtensionCatalogClient(
                    url: URL(string: "https://example.invalid/catalog")!,
                    publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                    repository: MarketplaceConfiguration.repository,
                    cache: root.appendingPathComponent("catalog.json"),
                    fetch: { _ in
                        Issue.record("Suite rendering cannot fetch the catalog")
                        throw MarketplaceError.downloadFailed
                    }),
                installer: ExtensionPackageInstaller(
                    store: store,
                    download: { _, _ in
                        Issue.record("Suite rendering cannot download")
                        throw MarketplaceError.downloadFailed
                    }, verify: { _ in }),
                sessions: HostExtensionSessions(defaults: defaults) { package in
                    Issue.record("Suite rendering cannot start workers")
                    return HostWorker(
                        configuration: .init(
                            identity: identity, extensionID: package.id, version: package.version),
                        executable: URL(fileURLWithPath: "/usr/bin/false"))
                })
        }

        func clean() {
            UserDefaults(suiteName: marketplace.identity.defaultsSuite)?.removePersistentDomain(
                forName: marketplace.identity.defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
