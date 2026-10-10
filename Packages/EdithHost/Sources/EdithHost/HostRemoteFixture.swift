#if EDITH_CLI_FIXTURE
import AppKit
import CryptoKit
import Darwin
import EdithExtensionSupport
import EdithHostCore
import ExtensionKit
import ExtensionMarketplace
import Foundation

@MainActor
final class HostRemoteFixture: NSObject, NSApplicationDelegate, EXHostViewControllerDelegate {
    private let directory: URL
    private let identity: HostIdentity
    private let marketplace: HostMarketplace
    private let manager: HostRemoteSessionManager
    private let package: ExtensionPackage
    private var window: NSWindow!
    private var root: NSViewController!
    private var browser: EXAppExtensionBrowserViewController?
    private var remote: EXHostViewController?
    private var handle: HostRemoteSceneHandle?
    private var timer: Timer?
    private var busy = false
    private var phase = "starting"
    private var failure: String?
    private var previousUI: HostRemoteProcessIdentity?

    static func run(directory: URL) throws {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.remote-") == true
        else {
            throw HostWorkerError.rejected
        }
        let fixture = try HostRemoteFixture(directory: directory)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = fixture
        withExtendedLifetime(fixture) { application.run() }
    }

    private init(directory: URL) throws {
        self.directory = directory
        identity = try HostIdentity(
            identifier: Bundle.main.bundleIdentifier!,
            supportDirectory: directory.appendingPathComponent("support"))
        package = try JSONDecoder().decode(
            ExtensionPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("selected-package.json")))
        guard package.id == "sample", package.hostABI == HostContract.compatibility else {
            throw HostWorkerError.rejected
        }
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        try store.commit([package])
        let defaults = UserDefaults(suiteName: identity.defaultsSuite)!
        defaults.removePersistentDomain(forName: identity.defaultsSuite)
        let executable = Bundle.main.executableURL!
        let fixtureIdentity = identity
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: fixtureIdentity, extensionID: package.id, version: package.version),
                executable: executable, arguments: ["--extension-remote-fixture-engine"])
        }
        let client = ExtensionCatalogClient(
            url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            repository: MarketplaceConfiguration.repository,
            cache: identity.root.appendingPathComponent("catalog.json"),
            fetch: { _ in throw MarketplaceError.downloadFailed })
        marketplace = try HostMarketplace(
            identity: identity,
            entries: [
                HostExtension(
                    id: "sample", title: "Synthetic owned scene", symbolName: "square",
                    category: "Tools")
            ],
            store: store, catalogClient: client,
            installer: ExtensionPackageInstaller(
                store: store,
                download: { _, _ in throw MarketplaceError.downloadFailed }, verify: { _ in }),
            sessions: sessions)
        manager = HostRemoteSessionManager(marketplace: marketplace)
        super.init()
        manager.detach = { [weak self] _ in self?.detach() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Synthetic owned remote scene"
        root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        let label = NSTextField(labelWithString: "Host-owned navigation")
        label.frame = NSRect(x: 15, y: 590, width: 200, height: 35)
        root.view.addSubview(label)
        window.contentViewController = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await marketplace.sessions.enable(package)
                try await open()
            } catch { report(error) }
        }
    }

    private func open() async throws {
        guard handle == nil else { throw HostWorkerError.rejected }
        let next = try await manager.scene(
            for: EdithHostCore.HostExtensionContentRequest(
                extensionID: "sample", location: "main", section: "sample"))
        handle = next
        previousUI = next.processIdentity
        failure = nil
        let controller = EXHostViewController()
        controller.delegate = self
        controller.configuration = .init(appExtension: next.identity, sceneID: next.sceneIdentifier)
        controller.view.frame = NSRect(x: 230, y: 0, width: 670, height: 650)
        controller.view.autoresizingMask = [.width, .height]
        root.addChild(controller)
        root.view.addSubview(controller.view)
        remote = controller
        phase = "attaching"
        writeState()
    }

    func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
        guard viewController === remote, let handle else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await handle.connect(
                    through: viewController.makeXPCConnection(),
                    compact: false, visible: true, width: 670)
                phase = "active"
                writeState()
            } catch { report(error) }
        }
    }

    func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: Error?) {
        if viewController === remote, phase == "active", let error { report(error) }
    }

    private func detach() {
        remote?.configuration = nil
        remote?.view.removeFromSuperview()
        remote?.removeFromParent()
        remote = nil
    }

    private func close() async throws {
        guard let handle else { throw HostWorkerError.rejected }
        detach()
        try await manager.endPresentation(id: handle.presentationID)
        self.handle = nil
        phase = "closed"
        writeState()
    }

    private func poll() {
        guard !busy,
            let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            let command = value["command"]
        else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("command.json"))
        busy = true
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false }
            do {
                switch command {
                case "open": try await open()
                case "close": try await close()
                case "disable":
                    detach()
                    try await marketplace.sessions.disable(id: "sample")
                    handle = nil
                    phase = "disabled"
                case "enable":
                    try await marketplace.sessions.enable(package)
                    phase = "enabled"
                case "approval":
                    let browser = EXAppExtensionBrowserViewController()
                    browser.view.frame = NSRect(x: 230, y: 0, width: 670, height: 650)
                    root.addChild(browser)
                    root.view.addSubview(browser.view)
                    self.browser = browser
                    phase = "approval"
                case "approved":
                    browser?.view.removeFromSuperview()
                    browser?.removeFromParent()
                    browser = nil
                    try await open()
                case "quit":
                    guard await marketplace.sessions.shutdown() else {
                        throw HostWorkerError.stillRunning
                    }
                    phase = "stopped"
                    writeState()
                    NSApp.terminate(nil)
                default: throw HostWorkerError.rejected
                }
                writeState()
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        failure = String(describing: error)
        phase = "error"
        writeState()
    }

    private func writeState() {
        let lease = try? PackageFileLock(
            url: marketplace.packageStore.leaseURL(for: package), exclusive: true)
        let leaseAvailable = lease != nil
        lease?.close()
        let object: [String: Any] = [
            "phase": phase, "error": failure as Any? ?? NSNull(),
            "uiPID": previousUI?.pid as Any? ?? NSNull(),
            "uiGeneration": previousUI?.generation as Any? ?? NSNull(),
            "uiRunning": previousUI?.isRunning ?? false, "leaseAvailable": leaseAvailable,
            "hostPID": getpid(),
            "enginePID": marketplace.sessions.processIdentifiers["sample"] as Any? ?? NSNull(),
            "remoteSessions": HostRemoteSession.extensionIDs.sorted(),
            "presentation": handle?.presentationID.uuidString as Any? ?? NSNull(),
            "engineRecord": identity.extensionDirectory("sample").appendingPathComponent(
                "record.json"
            ).path,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) {
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }
}
#endif
