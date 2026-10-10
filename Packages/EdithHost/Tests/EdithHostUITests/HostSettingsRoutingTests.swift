import CryptoKit
import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostSettingsRoutingTests {
    @Test(arguments: [
        "usage", "music", "jev", "downloads", "clipboard", "bifrost", "codeStats", "lidAwake",
    ])
    func activeFormsRequireTheSelectedEngineVersionAndUseTheirExactExport(id: String) throws {
        let package = package(id)
        let token = UUID()
        let request = try #require(
            self.request(
                id, installed: package, state: .active, version: package.version, token: token))
        #expect(request.extensionID == id)
        #expect(request.location == "settings")
        #expect(request.section == (["usage", "music", "jev"].contains(id) ? id : "extension"))
        #expect(request.presentationID == token)
        #expect(request.surface == nil && request.machinesWindow == nil)
        try request.validate(extensionID: id)
        let decoded = try JSONDecoder().decode(
            HostExtensionContentRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        for state in [HostActivationState.disabled, .starting, .stopping, .failed, .notInstalled] {
            #expect(
                self.request(id, installed: package, state: state, version: package.version) == nil)
        }
        #expect(self.request(id, installed: package, state: .active, version: "0.9.0") == nil)
        #expect(self.request(id, installed: package, state: .active, version: nil) == nil)
    }

    @Test(arguments: [
        "colorPicker", "emoji", "focusDim", "keepAwake", "keystrokeHighlight", "micMute",
        "presenter", "systemStats", "windowSweaters",
    ])
    func installedPreferenceFormsRemainAvailableWithoutStartingAnEngine(id: String) throws {
        let request = try #require(self.request(id, installed: package(id), state: .disabled))
        #expect(request.section == "extension" && request.location == "settings")
        #expect(HostExtensionSettingsPolicy.policy(for: id) == .preferences)
        try request.validate(extensionID: id)
    }

    @Test func absentIncompatibleForeignAndRetiringPackagesCannotCreateAnySettingsRequest() {
        for id in ["emoji", "usage", "music"] {
            #expect(request(id, installed: nil, state: .active, version: "1.0.0") == nil)
            for installed in [
                package(id, hostABI: "obsolete"), package(id, architecture: "x86_64"),
                package(id, minimumSystemVersion: 31), package("foreign"),
            ] {
                #expect(request(id, installed: installed, state: .active, version: "1.0.0") == nil)
            }
            #expect(
                request(
                    id, installed: package(id), state: .active, version: "1.0.0",
                    pendingDisable: true) == nil)
            #expect(
                request(
                    id, installed: package(id), state: .active, version: "1.0.0",
                    pendingRemoval: true) == nil)
            #expect(request(id, installed: package(id), state: .stopping, version: "1.0.0") == nil)
        }
    }

    @Test(arguments: [
        "herdr", "machines", "database", "docs", "studio", "attention", "appMaintenance", "quinjet",
        "notchShelf", "unknown",
    ])
    func unverifiedFormsNeverSubstituteAMainPageOrNotificationPane(id: String) {
        #expect(HostExtensionSettingsPolicy.route(for: id) == nil)
        #expect(request(id, installed: package(id), state: .active, version: "1.0.0") == nil)
    }

    @Test func reviewAdapterUsesActualCompatibleSelectionAndLeavesDisabledWorkersUnstarted() throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let token = UUID()
        let settings = try #require(
            HostExtensionReview.settingsRequest(
                id: "emoji", marketplace: fixture.marketplace, presentationID: token))
        #expect(settings.extensionID == "emoji" && settings.section == "extension")
        #expect(settings.presentationID == token)
        #expect(
            HostExtensionReview.settingsRequest(id: "usage", marketplace: fixture.marketplace)
                == nil)
        #expect(
            HostExtensionReview.settingsRequest(id: "music", marketplace: fixture.marketplace)
                == nil)
        #expect(
            HostExtensionReview.settingsRequest(id: "jev", marketplace: fixture.marketplace) == nil)
        fixture.defaults.set(["emoji"], forKey: HostExtensionSessions.enabledExtensionsKey)
        fixture.marketplace.sessions.requestDisable(ids: ["emoji"])
        #expect(
            HostExtensionReview.settingsRequest(id: "emoji", marketplace: fixture.marketplace)
                == nil)
        #expect(fixture.counter.starts == 0)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
    }

    private func request(
        _ id: String, installed: ExtensionPackage?, state: HostActivationState?,
        version: String? = nil,
        pendingDisable: Bool = false, pendingRemoval: Bool = false, token: UUID = UUID()
    ) -> HostExtensionContentRequest? {
        HostExtensionSettingsPolicy.request(
            id: id, installed: installed, state: state, activeVersion: version,
            pendingDisable: pendingDisable, pendingRemoval: pendingRemoval,
            presentationID: token, systemVersion: 30)
    }

    private func package(
        _ id: String, hostABI: String = HostContract.compatibility, architecture: String = "arm64",
        minimumSystemVersion: Int = 14
    ) -> ExtensionPackage {
        .init(
            id: id, version: "1.0.0", hostABI: hostABI, architecture: architecture,
            minimumSystemVersion: minimumSystemVersion,
            downloadURL: URL(string: "https://example.invalid/package.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 100, installedBytes: 200)
    }

    @MainActor private final class Counter { var starts = 0 }

    @MainActor private struct Fixture {
        let root: URL
        let marketplace: HostMarketplace
        let defaults: UserDefaults
        let counter: Counter

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.settings-" + UUID().uuidString,
                supportDirectory: root)
            defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            counter = Counter()
            let counter = counter
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            let packages = ["emoji", "usage", "music"].map {
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
            marketplace = try HostMarketplace(
                identity: identity, entries: HostIndex.bundled(), store: store,
                catalogClient: ExtensionCatalogClient(
                    url: URL(string: "https://example.invalid/catalog")!,
                    publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                    repository: MarketplaceConfiguration.repository,
                    cache: root.appendingPathComponent("catalog.json"),
                    fetch: { _ in
                        Issue.record("Settings routing cannot fetch");
                        throw MarketplaceError.downloadFailed
                    }),
                installer: ExtensionPackageInstaller(
                    store: store,
                    download: { _, _ in
                        Issue.record("Settings routing cannot download");
                        throw MarketplaceError.downloadFailed
                    },
                    verify: { _ in }),
                sessions: HostExtensionSessions(defaults: defaults) { package in
                    counter.starts += 1
                    Issue.record("Settings routing cannot start workers")
                    return HostWorker(
                        configuration: .init(
                            identity: identity, extensionID: package.id, version: package.version),
                        executable: URL(fileURLWithPath: "/usr/bin/false"))
                })
        }

        func clean() {
            defaults.removePersistentDomain(forName: marketplace.identity.defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
