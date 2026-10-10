#if EDITH_GUI_FIXTURE
import CryptoKit
import AppKit
import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import Foundation
import SwiftUI

@MainActor enum HostGUIFixture {
    static var environmentVisible = false
    static func make() throws -> HostMarketplace {
        guard let identifier = Bundle.main.bundleIdentifier,
            identifier.hasPrefix("com.pulkit.edith.tests.gui-"),
            let directoryPath = ProcessInfo.processInfo.environment["EDITH_GUI_FIXTURE_DIRECTORY"],
            let home = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"],
            let executable = Bundle.main.executableURL
        else { throw HostWorkerError.rejected }
        let directory = URL(fileURLWithPath: directoryPath).resolvingSymlinksInPath()
        let homeDirectory = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        guard directory.lastPathComponent.hasPrefix("edith-gui-fixture-"),
            homeDirectory == directory.appendingPathComponent("Home"),
            Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/")
        else { throw HostWorkerError.rejected }
        let identity = try HostIdentity(
            identifier: identifier,
            supportDirectory: homeDirectory.appendingPathComponent("Support"))
        let packages = try JSONDecoder().decode(
            [ExtensionPackage].self,
            from: Data(contentsOf: directory.appendingPathComponent("packages.json")))
        guard packages.count == 1, packages.first?.id == "calendar" else {
            throw HostWorkerError.rejected
        }
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 90, count: 32))
        let payload = try JSONEncoder().encode(ExtensionCatalog(revision: 1, packages: packages))
        let envelope = try JSONEncoder().encode(
            SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        try FileManager.default.createDirectory(
            at: identity.root, withIntermediateDirectories: true)
        let cache = identity.root.appendingPathComponent("catalog.json")
        try envelope.write(to: cache, options: .atomic)
        let catalog = ExtensionCatalogClient(
            url: MarketplaceConfiguration.catalogURL, publicKey: key.publicKey.rawRepresentation,
            repository: MarketplaceConfiguration.repository, cache: cache, fetch: { _ in envelope })
        let installer = ExtensionPackageInstaller(
            store: store,
            download: { url, count in
                guard url.lastPathComponent == "calendar.zip" else {
                    throw MarketplaceError.downloadFailed
                }
                let data = try Data(contentsOf: directory.appendingPathComponent("calendar.zip"))
                guard data.count == count else { throw MarketplaceError.downloadFailed }
                let temporary = directory.appendingPathComponent(UUID().uuidString + ".zip")
                try data.write(to: temporary)
                return temporary
            },
            verify: { payload in
                try ExtensionCodeSignature.verifyDevelopment(
                    payload.appendingPathComponent("app.bundle"))
            })
        guard let defaults = UserDefaults(suiteName: identity.defaultsSuite) else {
            throw HostWorkerError.rejected
        }
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                executable: executable, errorOutput: .standardError)
        }
        let marketplace = try HostMarketplace(
            identity: identity,
            entries: [
                HostExtension(
                    id: "calendar", title: "Calendar", symbolName: "calendar", category: "Tools")
            ],
            store: store, catalogClient: catalog, installer: installer, sessions: sessions)
        marketplace.automaticallyUpdatesExtensions = false
        Task { [weak marketplace] in
            while let marketplace, !Task.isCancelled {
                guard let home = try? JSONEncoder().encode(marketplace.surfaceLayouts.home),
                    let notch = try? JSONEncoder().encode(marketplace.surfaceLayouts.notch),
                    let homeObject = try? JSONSerialization.jsonObject(with: home),
                    let notchObject = try? JSONSerialization.jsonObject(with: notch)
                else { return }
                let record: [String: Any] = [
                    "pid": getpid(), "root": identity.root.path,
                    "downloaded": marketplace.downloadedIDs.sorted(),
                    "active": marketplace.surfaceAvailability.activeIDs.sorted(),
                    "workers": marketplace.sessions.processIdentifiers,
                    "windowVisible": NSApp.windows.contains {
                        $0.isVisible && $0.occlusionState.contains(.visible)
                    },
                    "applicationHidden": NSApp.isHidden,
                    "environmentVisible": Self.environmentVisible,
                    "versions": marketplace.sessions.versions,
                    "error": marketplace.error ?? "",
                    "home": homeObject, "notch": notchObject,
                    "visibleHome": marketplace.surfaceAvailability.projected(
                        marketplace.surfaceLayouts.home, target: .home
                    ).tiles.map(\.id),
                    "visibleNotch": marketplace.surfaceAvailability.projected(
                        marketplace.surfaceLayouts.notch, target: .notch
                    ).tiles.map(\.id),
                ]
                try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(
                    to: directory.appendingPathComponent("state.json"), options: .atomic)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return marketplace
    }
}

struct HostGUIVisibilityProbe: View {
    @Environment(\.windowVisible) private var visible
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { HostGUIFixture.environmentVisible = visible }
            .onChange(of: visible) { HostGUIFixture.environmentVisible = visible }
    }
}
#endif
