#if EDITH_CLI_FIXTURE
import EdithHostCore
import ExtensionMarketplace
import Foundation

@MainActor enum HostCLIFixture {
    static func run(directory: URL) throws {
        guard let identifier = Bundle.main.bundleIdentifier,
            identifier.hasPrefix("com.pulkit.edith.tests.cli-"),
            let executable = Bundle.main.executableURL
        else { throw HostCLIError.unavailable }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let identity = try HostIdentity(identifier: identifier, supportDirectory: support)
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let client = ExtensionCatalogClient(
            url: MarketplaceConfiguration.catalogURL,
            publicKey: try Data(contentsOf: directory.appendingPathComponent("public.key")),
            repository: MarketplaceConfiguration.repository,
            cache: identity.root.appendingPathComponent("catalog.json")
        ) { _ in try Data(contentsOf: directory.appendingPathComponent("catalog.json")) }
        let installer = ExtensionPackageInstaller(
            store: store,
            download: { url, count in
                let archive = directory.appendingPathComponent(
                    url.deletingLastPathComponent().lastPathComponent + ".zip")
                let data = try Data(contentsOf: archive)
                guard data.count == count else { throw MarketplaceError.downloadFailed }
                let temporary = directory.appendingPathComponent(UUID().uuidString + ".zip")
                try data.write(to: temporary)
                return temporary
            },
            verify: { payload in
                for bundle in try FileManager.default.contentsOfDirectory(
                    at: payload, includingPropertiesForKeys: nil)
                where bundle.pathExtension == "bundle" {
                    try ExtensionCodeSignature.verifyDevelopment(bundle)
                }
            })
        guard let defaults = UserDefaults(suiteName: identity.defaultsSuite) else {
            throw HostCLIError.unavailable
        }
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                executable: executable)
        }
        let marketplace = try HostMarketplace(
            identity: identity, entries: HostIndex.bundled(), store: store,
            catalogClient: client, installer: installer, sessions: sessions)
        let gateway = HostCLIGateway(marketplace: marketplace)
        let server = HostCLIServer(identity: identity) { try await gateway.execute($0) }
        try server.start()
        try JSONSerialization.data(withJSONObject: [
            "pid": getpid(), "root": identity.root.path,
            "socket": HostCLITransport.socketPath(identity: identity),
        ]).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
        Task {
            while !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("stop").path)
            {
                try? await Task.sleep(for: .milliseconds(100))
            }
            _ = await sessions.shutdown()
            server.shutdown()
            defaults.removePersistentDomain(forName: identity.defaultsSuite)
            UserDefaults(suiteName: identity.extensionDefaultsSuite("keepAwake"))?
                .removePersistentDomain(forName: identity.extensionDefaultsSuite("keepAwake"))
            try? await Task.sleep(for: .milliseconds(100))
            exit(0)
        }
        dispatchMain()
    }
}

#endif
