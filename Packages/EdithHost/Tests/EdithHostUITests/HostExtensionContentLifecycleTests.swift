import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import HostWorkerFixtureSupport
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostExtensionContentLifecycleTests {
    @Test func sameVersionRestartReplacesThePageAndParksItsOriginalGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let marketplace = fixture.marketplace
        let presenter = Presenter()
        try await marketplace.sessions.enable(fixture.package)
        let original = try #require(marketplace.sessions.generations["docs"])
        let window = TestWindowHost.window(contentRect: .init(x: 0, y: 0, width: 880, height: 640))
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: HostExtensionContent(
                marketplace: marketplace, extensionID: "docs", location: "main",
                presenter: presenter, openMarketplace: {}
            )
            .environment(\.automaticViewActionsEnabled, true))
        window.orderBack(nil)
        defer { window.close() }
        try await settle { presenter.created == 1 }
        try await marketplace.sessions.disable(id: "docs")
        try await settle { !presenter.parked.isEmpty }
        #expect(presenter.parked.first?.version == "1.0.0:" + original.uuidString)
        try await marketplace.sessions.enable(fixture.package)
        try await settle { presenter.created == 2 }
        #expect(marketplace.sessions.generations["docs"] != original)
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func anIdleSettingsPageRebuildsOnceItsSwitchStartsTheExtension() async throws {
        let fixture = try Fixture(launchWhen: [.init(key: "docsActive", default: false)])
        defer { fixture.clean() }
        let marketplace = fixture.marketplace
        let identity = marketplace.identity
        let presenter = Presenter()
        try #require(UserDefaults(suiteName: identity.defaultsSuite)).set(
            ["docs"], forKey: HostExtensionSessions.enabledExtensionsKey)
        await marketplace.restoreEnabledExtensions()
        #expect(marketplace.sessions.states["docs"] == .idle)
        let window = TestWindowHost.window(contentRect: .init(x: 0, y: 0, width: 880, height: 640))
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: HostExtensionContent(
                marketplace: marketplace, extensionID: "docs", location: "settings",
                presenter: presenter, openMarketplace: {}
            )
            .environment(\.automaticViewActionsEnabled, true))
        window.orderBack(nil)
        defer { window.close() }
        try await settle { presenter.created == 1 }
        try #require(UserDefaults(suiteName: identity.extensionDefaultsSuite("docs"))).set(
            true, forKey: "docsActive")
        IPC.post(IPC.Name.settingsChanged)
        try await settle { presenter.created == 2 }
        #expect(marketplace.sessions.states["docs"] == .active)
        #expect(await marketplace.sessions.shutdown())
    }

    private func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("The extension page did not finish its lifecycle transition")
                throw HostWorkerError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private final class Presenter: HostExtensionContentPresenting {
        var created = 0
        var parked: [(version: String, id: UUID, controller: NSViewController)] = []
        func controller(for request: HostExtensionContentRequest) async throws -> NSViewController {
            created += 1
            return NSHostingController(rootView: Text("Synthetic documentation"))
        }
        func endPresentation(id: UUID) { parked.removeAll { $0.id == id } }
        func park(key: String, version: String, presentationID: UUID, controller: NSViewController)
        {
            parked.append((version, presentationID, controller))
        }
        func unpark(key: String, version: String) -> (
            presentationID: UUID, controller: NSViewController
        )? {
            guard let entry = parked.first(where: { $0.version == version }) else { return nil }
            parked.removeAll { $0.id == entry.id }
            return (entry.id, entry.controller)
        }
    }

    @MainActor private struct Fixture {
        let root: URL
        let marketplace: HostMarketplace
        let package: ExtensionPackage
        init(launchWhen: [HostLaunchCondition] = []) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.content." + UUID().uuidString,
                supportDirectory: root)
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            package = ExtensionPackage(
                id: "docs", version: "1.0.0", hostABI: HostContract.compatibility,
                downloadURL: URL(
                    string: "https://github.com/example/app/releases/download/test/docs.zip")!,
                sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
            let store = ExtensionPackageStore(root: root.appendingPathComponent("Extensions"))
            try store.commit([package])
            marketplace = try HostMarketplace(
                identity: identity,
                entries: [
                    .init(
                        id: "docs", title: "Docs", icon: .book, category: "agents",
                        background: launchWhen.isEmpty, launchWhen: launchWhen)
                ],
                store: store,
                catalogClient: ExtensionCatalogClient(
                    url: URL(string: "https://example.invalid/catalog")!, publicKey: Data(),
                    repository: "example/app", cache: root.appendingPathComponent("catalog.json"),
                    fetch: { _ in throw MarketplaceError.downloadFailed }),
                installer: ExtensionPackageInstaller(
                    store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                    verify: { _ in }),
                sessions: HostExtensionSessions(defaults: defaults) { package in
                    HostWorker(
                        configuration: .init(
                            identity: identity, extensionID: package.id, version: package.version),
                        engine: FixtureWorkerEngine.factory(mode: "normal"))
                })
        }
        func clean() {
            UserDefaults(suiteName: marketplace.identity.defaultsSuite)?.removePersistentDomain(
                forName: marketplace.identity.defaultsSuite)
            let extensionSuite = marketplace.identity.extensionDefaultsSuite("docs")
            UserDefaults(suiteName: extensionSuite)?.removePersistentDomain(forName: extensionSuite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
