#if EDITH_CLI_FIXTURE
import AppKit
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
                let manifest = try JSONDecoder().decode(
                    ExtensionPayloadManifest.self,
                    from: Data(contentsOf: payload.appendingPathComponent("package.json")))
                let carrier = try ExtensionUICarrier(
                    payload: payload, manifest: manifest, expectedHostIdentifier: identifier)
                try carrier.verifyDevelopment()
                for bundle in try FileManager.default.contentsOfDirectory(
                    at: carrier.payloadDirectory, includingPropertiesForKeys: nil)
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
                executable: executable, errorOutput: .standardError)
        }
        let marketplace = try HostMarketplace(
            identity: identity, entries: HostIndex.bundled(), store: store,
            catalogClient: client, installer: installer, sessions: sessions)
        let gateway = HostCLIGateway(marketplace: marketplace)
        let standardSuite = identifier + ".cli-fixture"
        guard let standard = UserDefaults(suiteName: standardSuite) else {
            throw HostCLIError.unavailable
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = HostApplicationDelegate()
        delegate.activate = { preconditionFailure("The CLI fixture cannot activate windows.") }
        delegate.mainWindow = { nil }
        var requestQuit: @MainActor () -> Void = {}
        let coreFixture =
            ProcessInfo.processInfo.environment["EDITH_CORE_CLI_FIXTURE"] == "1"
            ? HostCoreAgentCLIFixture(
                identity: identity, executable: executable, directory: directory) : nil
        let core = try HostCoreCLIAdapter.make(
            identity: identity, marketplace: marketplace,
            updater: HostUpdater(startingUpdater: false),
            shared: defaults, standard: standard,
            permissionState: HostPermissions(
                environment: HostPermissionEnvironment(
                    read: {
                        Dictionary(
                            uniqueKeysWithValues: HostPermission.allCases.map { ($0, false) })
                    },
                    request: { _ in
                        preconditionFailure("Permission requests are disabled in the CLI fixture.")
                    },
                    openSettings: { _ in
                        preconditionFailure("OS settings are disabled in the CLI fixture.")
                    })),
            showMainWindow: { preconditionFailure("The CLI fixture cannot open windows.") },
            navigation: { _, _ in throw HostCLIError.rejected("No fixture window is available.") },
            agentBackend: coreFixture?.backend,
            quit: { requestQuit() }, changed: {})
        let server = HostCLIServer(identity: identity) { request in
            if HostCoreCLIService.handles(request) {
                if request.operation == "host.cli" {
                    let envelope = try JSONDecoder().decode(
                        HostCoreCLIEnvelope.self, from: request.payload)
                    let safe = ["info", "diagnostics", "paths", "links", "actions", "quit"]
                    guard
                        envelope.arguments.first == "config"
                            || coreFixture != nil && envelope.arguments.first == "agent"
                            || envelope.arguments.first == "extensions"
                                && ["status", "verify", "doctor", "setup"].contains(
                                    envelope.arguments.dropFirst().first ?? "")
                            || envelope.arguments.first == "app"
                                && safe.contains(envelope.arguments.dropFirst().first ?? "")
                            || envelope.arguments.first == "permissions"
                                && ["ls", "list", "refresh"].contains(
                                    envelope.arguments.dropFirst().first ?? "ls")
                    else {
                        throw HostCLIError.rejected("OS actions are disabled in the CLI fixture.")
                    }
                }
                return try await core.execute(request)
            }
            return try await gateway.execute(request)
        }
        try server.start()
        delegate.shutdown = {
            guard await sessions.shutdown() else { exit(1) }
            core.shutdown(); server.shutdown()
            await coreFixture?.shutdown()
            let socket = try? HostCLITransport.socketPath(identity: identity)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while let socket, FileManager.default.fileExists(atPath: socket),
                ContinuousClock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if let socket, FileManager.default.fileExists(atPath: socket) { exit(1) }
            defaults.removePersistentDomain(forName: identity.defaultsSuite)
            standard.removePersistentDomain(forName: standardSuite)
            for id in ["keepAwake", "calendar"] {
                UserDefaults(suiteName: identity.extensionDefaultsSuite(id))?
                    .removePersistentDomain(forName: identity.extensionDefaultsSuite(id))
            }
            try? JSONSerialization.data(withJSONObject: [
                "coreStopped": true, "activeWorkers": sessions.activeIDs.count,
            ]).write(to: directory.appendingPathComponent("shutdown.json"), options: .atomic)
            return true
        }
        requestQuit = {
            Task {
                guard await delegate.shutdown?() == true else { exit(1) }
                exit(0)
            }
        }
        application.delegate = delegate
        try JSONSerialization.data(withJSONObject: [
            "pid": getpid(), "root": identity.root.path,
            "socket": HostCLITransport.socketPath(identity: identity),
        ]).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
        Task {
            do { try await coreFixture?.start() } catch {
                try? JSONSerialization.data(withJSONObject: ["error": String(describing: error)])
                    .write(
                        to: directory.appendingPathComponent("core-ready.json"), options: .atomic)
                requestQuit(); return
            }
            try? await Task.sleep(for: .milliseconds(100))
            try? JSONSerialization.data(withJSONObject: [
                "running": application.isRunning,
                "delegateInstalled": application.delegate as AnyObject? === delegate,
                "globalMatches": NSApp === application, "windows": application.windows.count,
                "active": application.isActive,
                "prohibited": application.activationPolicy() == .prohibited,
            ]).write(
                to: directory.appendingPathComponent("application-state.json"), options: .atomic)
            while !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("stop").path)
            {
                try? await Task.sleep(for: .milliseconds(100))
            }
            requestQuit()
        }
        withExtendedLifetime(delegate) { application.run() }
    }
}

#endif
