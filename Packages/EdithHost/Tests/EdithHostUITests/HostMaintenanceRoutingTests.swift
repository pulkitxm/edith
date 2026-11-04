import AppKit
import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import ExtensionMarketplace
import SwiftUI
import Testing

@testable import EdithHost
@testable import EdithHostCore

@MainActor @Suite(.serialized) struct HostMaintenanceRoutingTests {
    @Test func sectionRoutesLandOnTheRequestedMaintenanceSection() async throws {
        let fixture = try await Fixture()
        defer { fixture.clean() }
        let router = WindowRouter()
        defer { _ = router }
        let state = HarnessState()
        let window = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = NSHostingView(
            rootView: NavigationRouteHost(router: router, role: .main) {
                Harness(marketplace: fixture.marketplace, state: state)
            })
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle()
        for (route, expected) in [
            ("appMaintenance/Remove", "Remove"), ("appMaintenance/Packages", "Packages"),
            ("appMaintenance/History", "History"), ("appMaintenance/Updates", "Updates"),
        ] {
            let reply = NavigationCommands.perform(action: "navigate", route: route)
            await settle()
            #expect(reply["ok"] as? Bool == true)
            #expect(state.page == "appMaintenance")
            #expect(state.maintenance == expected)
            #expect(
                NavigationCommands.perform(action: "route", route: nil)["route"] as? String == route
            )
        }
        _ = NavigationCommands.perform(action: "navigate", route: "appMaintenance/Cleaner")
        await settle()
        #expect(state.maintenance == "Updates")
    }

    @Test func pagesStayNavigableWhileTheirExtensionIsStarting() {
        let ids: Set<String> = ["database", "blitztree", "music", "usage", "herdr"]
        let states: [String: HostActivationState] = [
            "database": .idle, "blitztree": .starting, "music": .active, "usage": .disabled,
            "herdr": .failed,
        ]
        let availability = HostSurfaceAvailability(
            knownIDs: ids, installedIDs: ids, downloadedIDs: ids, states: states)
        #expect(availability.navigableIDs == ["database", "blitztree", "music"])
        #expect(availability.activeIDs == ["database", "music"])
        let defaults = UserDefaults(suiteName: "navigable-" + UUID().uuidString)!
        #expect(
            HostNavigationCatalog.resolve(
                "blitztree", active: availability.activeIDs, defaults: defaults) == "home")
        #expect(
            HostNavigationCatalog.resolve(
                "blitztree", active: availability.navigableIDs, defaults: defaults) == "blitztree")
    }

    @MainActor final class HarnessState {
        var page = "appMaintenance"
        var maintenance = "Updates"
    }

    private struct Harness: View {
        let marketplace: HostMarketplace
        let state: HarnessState
        @State private var page = "appMaintenance"
        @State private var settings = "general"
        @State private var maintenance = "Updates"

        var body: some View {
            HostPageContent(
                marketplace: marketplace, updater: HostUpdater(startingUpdater: false),
                permissions: HostPermissions(), destination: HostNavigationCatalog.page(page),
                settings: $settings, maintenanceSection: $maintenance, select: { page = $0 }
            )
            .navigationRoute("section", selection: $page)
            .onChange(of: page, initial: true) { _, value in state.page = value }
            .onChange(of: maintenance, initial: true) { _, value in state.maintenance = value }
        }
    }

    private func settle() async {
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor private struct Fixture {
        let root: URL
        let marketplace: HostMarketplace

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.maintenance-" + UUID().uuidString,
                supportDirectory: root)
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            let packages = ["appMaintenance", "homebrew"].map {
                ExtensionPackage(
                    id: $0, version: "1.0.0", hostABI: HostContract.compatibility,
                    downloadURL: URL(string: "https://example.invalid/\($0).zip")!,
                    sha256: String(repeating: "a", count: 64), downloadBytes: 100,
                    installedBytes: 200)
            }
            for package in packages {
                try FileManager.default.createDirectory(
                    at: store.directory(for: package), withIntermediateDirectories: true)
            }
            try store.commit(packages)
            defaults.set(
                packages.map(\.id), forKey: HostExtensionSessions.enabledExtensionsKey)
            marketplace = try HostMarketplace(
                identity: identity, entries: HostIndex.bundled(), store: store,
                catalogClient: ExtensionCatalogClient(
                    url: URL(string: "https://example.invalid/catalog")!,
                    publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                    repository: MarketplaceConfiguration.repository,
                    cache: root.appendingPathComponent("catalog.json"),
                    fetch: { _ in throw MarketplaceError.downloadFailed }),
                installer: ExtensionPackageInstaller(
                    store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                    verify: { _ in }),
                sessions: HostExtensionSessions(defaults: defaults) { _ in
                    throw HostWorkerError.rejected
                })
            marketplace.sessions.startsAtLaunch = { _ in false }
            await marketplace.sessions.restore(
                packages: Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) }))
        }

        func clean() {
            marketplace.surfaces.navigation.shutdown(); marketplace.surfaces.requests.shutdown()
            marketplace.surfaces.privacy.shutdown()
            UserDefaults(suiteName: marketplace.identity.defaultsSuite)?
                .removePersistentDomain(forName: marketplace.identity.defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
