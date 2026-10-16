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
    private let registrationOnly: Bool
    private let managedShipping: Bool
    private let retainedPackages: [ExtensionPackage]
    private var window: NSWindow!
    private var root: NSViewController!
    private var browser: EXAppExtensionBrowserViewController?
    private var remote: EXHostViewController?
    private var handle: HostRemoteSceneHandle?
    private var activation: Task<Void, Never>?
    private var timer: Timer?
    private var busy = false
    private var phase = "starting"
    private var failure: String?
    private var previousUI: HostRemoteProcessIdentity?

    static func run(directory: URL, registrationOnly: Bool = false) throws {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.remote-") == true
        else {
            throw HostWorkerError.rejected
        }
        let fixture = try HostRemoteFixture(
            directory: directory, registrationOnly: registrationOnly)
        let application = NSApplication.shared
        application.setActivationPolicy(registrationOnly ? .prohibited : .regular)
        application.delegate = fixture
        withExtendedLifetime(fixture) { application.run() }
    }

    private init(directory: URL, registrationOnly: Bool) throws {
        self.directory = directory
        self.registrationOnly = registrationOnly
        managedShipping = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("managed-shipping-fixture.json").path)
        guard
            !managedShipping
                || (registrationOnly
                    && ProcessInfo.processInfo.environment["EDITH_REMOTE_OFFSCREEN_FIXTURE"] != "1")
        else { throw HostWorkerError.rejected }
        identity = try HostIdentity(
            identifier: Bundle.main.bundleIdentifier!,
            supportDirectory: directory.appendingPathComponent("support"))
        package = try JSONDecoder().decode(
            ExtensionPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("selected-package.json")))
        guard package.hostABI == HostContract.compatibility,
            managedShipping ? package.id != "sample" : package.id == "sample"
        else {
            throw HostWorkerError.rejected
        }
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let retainedURL = directory.appendingPathComponent("retained-packages.json")
        let retained =
            FileManager.default.fileExists(atPath: retainedURL.path)
            ? try JSONDecoder().decode([ExtensionPackage].self, from: Data(contentsOf: retainedURL))
            : []
        let selectedPackage = package
        guard retained.count < 8,
            retained.allSatisfy({
                $0.id == selectedPackage.id && $0.hostABI == selectedPackage.hostABI
                    && $0.version != selectedPackage.version
            })
        else { throw HostWorkerError.rejected }
        retainedPackages = retained
        try store.commit(retained + [package])
        try store.select(package)
        let defaults = UserDefaults(suiteName: identity.defaultsSuite)!
        defaults.removePersistentDomain(forName: identity.defaultsSuite)
        let executable = Bundle.main.executableURL!
        let fixtureIdentity = identity
        let shipping = managedShipping
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: fixtureIdentity, extensionID: package.id, version: package.version),
                executable: executable,
                arguments: shipping ? ["--extension-worker"] : ["--extension-remote-fixture-engine"]
            )
        }
        let client = ExtensionCatalogClient(
            url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            repository: MarketplaceConfiguration.repository,
            cache: identity.root.appendingPathComponent("catalog.json"),
            fetch: { _ in throw MarketplaceError.downloadFailed })
        let entries: [HostExtension]
        if managedShipping {
            entries = try HostIndex.load(
                data: Data(
                    contentsOf:
                        directory.appendingPathComponent("managed-shipping-fixture.json")))
            guard entries.count == 1, entries[0].id == package.id,
                try HostIndex.bundled().contains(entries[0])
            else {
                throw HostWorkerError.rejected
            }
        } else {
            entries = [
                HostExtension(
                    id: "sample", title: "Synthetic owned scene",
                    symbolName: "square", category: "Tools")
            ]
        }
        marketplace = try HostMarketplace(
            identity: identity,
            entries: entries,
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
        if registrationOnly {
            Task {
                if managedShipping {
                    await verifyManagedShipping()
                } else {
                    await verifyRegistration()
                }
            }
            return
        }
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

    private func verifyManagedShipping() async {
        root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        window = NSWindow(contentViewController: root)
        window.isReleasedWhenClosed = false
        let resultURL = directory.appendingPathComponent("result-managed-shipping.json")
        do {
            try await marketplace.sessions.enable(package)
            guard let enginePID = marketplace.sessions.processIdentifiers[package.id],
                marketplace.sessions.versions[package.id] == package.version
            else { throw HostWorkerError.invalidResponse }
            var uiProcesses: [HostRemoteProcessIdentity] = []
            for _ in 0..<2 {
                let handle = try await manager.scene(
                    for: EdithHostCore.HostExtensionContentRequest(
                        extensionID: package.id, location: "main", section: package.id))
                self.handle = handle
                attachRegistration(handle)
                let deadline = ContinuousClock.now + .seconds(15)
                while phase == "attaching", ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard phase == "active", handle.isPresented,
                    let peer = handle.processIdentity, peer.isRunning,
                    peer.pid != enginePID, peer.pid != getpid(),
                    marketplace.sessions.processIdentifiers[package.id] == enginePID,
                    marketplace.sessions.versions[package.id] == package.version,
                    !window.isVisible, !window.isKeyWindow, !window.isMainWindow
                else { throw HostWorkerError.invalidResponse }
                if let previous = uiProcesses.last {
                    guard !previous.isRunning, previous != peer else {
                        throw HostWorkerError.invalidResponse
                    }
                }
                uiProcesses.append(peer)
                let heldLease = try? PackageFileLock(
                    url: marketplace.packageStore.leaseURL(for: package), exclusive: true)
                guard heldLease == nil else {
                    heldLease?.close()
                    throw HostWorkerError.invalidResponse
                }
                try await manager.prepareToClose(id: handle.presentationID)
                remote?.configuration = nil
                if let remote { root.dismiss(remote) }
                try await manager.endPresentation(id: handle.presentationID)
                self.handle = nil
                remote = nil
                guard !peer.isRunning, manager.presentationCounts().isEmpty,
                    marketplace.sessions.processIdentifiers[package.id] == enginePID
                else { throw HostWorkerError.stillRunning }
            }
            try await marketplace.sessions.disable(id: package.id)
            guard marketplace.sessions.processIdentifiers.isEmpty,
                uiProcesses.allSatisfy({ !$0.isRunning }),
                manager.presentationCounts().isEmpty,
                !window.isVisible, !window.isKeyWindow, !window.isMainWindow
            else { throw HostWorkerError.stillRunning }
            window.close()
            window = nil
            guard await marketplace.sessions.shutdown() else { throw HostWorkerError.stillRunning }
            let lease = try PackageFileLock(
                url: marketplace.packageStore.leaseURL(for: package), exclusive: true)
            lease.close()
            let result: [String: Any] = [
                "outcome": "passed", "extensionID": package.id,
                "selectedVersion": package.version, "hostABI": package.hostABI,
                "managedNativeViewValidated": true, "nativeWindow": false,
                "originalDownloadedRole": true, "readonlyControlVerified": true,
                "publicCarrierCheckIn": true, "freshSceneGeneration": true,
                "lastCloseExited": true, "disableExitedBothRoles": true,
                "packageLeaseReleased": true, "noVisibleWindows": true,
                "disabledProcesses": 0,
            ]
            try JSONSerialization.data(withJSONObject: result, options: .sortedKeys).write(
                to: resultURL, options: .atomic)
            NSApp.terminate(nil)
        } catch {
            remote?.configuration = nil
            if let remote { root.dismiss(remote) }
            remote = nil
            window?.close()
            window = nil
            let stopped = await marketplace.sessions.shutdown()
            let result: [String: Any] = [
                "outcome": "failed", "extensionID": package.id,
                "managedNativeViewValidated": false, "nativeWindow": false,
                "error": String(describing: error), "cleanupVerified": stopped,
            ]
            try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys).write(
                to: resultURL, options: .atomic)
            NSApp.terminate(nil)
        }
    }

    private func verifyRegistration() async {
        root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        window = NSWindow(contentViewController: root)
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 900, height: 650), display: false)
        window.isReleasedWhenClosed = false
        do {
            var approvalRequired = false
            var rejectedRetainedCandidates = 0
            var verifiedRejectedUIExit = true
            let rejectsRetained =
                ProcessInfo.processInfo.environment["EDITH_REMOTE_RETAINED_NEGATIVE"] == "1"
            if let retained = retainedPackages.first, rejectsRetained {
                try await manager.fixturePrioritizeRetained(retained)
            }
            let cleansUnconnected =
                ProcessInfo.processInfo.environment["EDITH_REMOTE_UNCONNECTED_CLEANUP"] == "1"
            if cleansUnconnected { try await verifyUnconnectedCleanup() }
            do {
                if !cleansUnconnected {
                    let handle = try await manager.scene(
                        for: EdithHostCore.HostExtensionContentRequest(
                            extensionID: "sample", location: "settings", section: "extension"))
                    self.handle = handle
                    attachRegistration(handle)
                    let deadline = ContinuousClock.now + .seconds(12)
                    while phase == "attaching", ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    if rejectsRetained {
                        guard phase != "active", !handle.isPresented, handle.processIdentity == nil
                        else {
                            throw HostWorkerError.invalidResponse
                        }
                        let rejected = handle.fixtureRejectedProcesses
                        guard let retained = retainedPackages.first else {
                            throw HostWorkerError.rejected
                        }
                        let carrier = try ExtensionUICarrier(
                            payload: marketplace.packageStore.directory(for: retained)
                                .appendingPathComponent(retained.id),
                            package: retained, expectedHostIdentifier: identity.identifier)
                        let executable = carrier.worker.appendingPathComponent(
                            "Contents/MacOS/Edith"
                        )
                        .resolvingSymlinksInPath()
                        guard rejected.count == 1, rejected[0].executable == executable else {
                            throw HostWorkerError.invalidResponse
                        }
                        rejectedRetainedCandidates = rejected.count
                        remote?.configuration = nil
                        if let remote { root.dismiss(remote) }
                        try await manager.endPresentation(id: handle.presentationID)
                        verifiedRejectedUIExit = rejected.allSatisfy { !$0.isRunning }
                        guard verifiedRejectedUIExit else { throw HostWorkerError.stillRunning }
                        self.handle = nil
                        phase = "rejected"
                    } else {
                        guard phase == "active", handle.isPresented,
                            let peer = handle.processIdentity,
                            peer.isRunning
                        else {
                            throw NSError(
                                domain: "remote-fixture", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: failure ?? "timedOut"])
                        }
                        previousUI = peer
                        let rejected = handle.fixtureRejectedProcesses
                        rejectedRetainedCandidates = rejected.count
                        verifiedRejectedUIExit = rejected.allSatisfy { !$0.isRunning }
                        guard rejected.isEmpty else { throw HostWorkerError.invalidResponse }
                        try await manager.prepareToClose(id: handle.presentationID)
                        remote?.configuration = nil
                        if let remote { root.dismiss(remote) }
                        try await manager.endPresentation(id: handle.presentationID)
                        self.handle = nil
                    }
                }
            } catch HostRemoteAvailabilityError.approvalRequired {
                approvalRequired = true
            }
            remote?.configuration = nil
            if let remote { root.dismiss(remote) }
            remote = nil
            let remainedInvisible = !window.isVisible && !window.isKeyWindow && !window.isMainWindow
            window.close()
            window = nil
            guard await marketplace.sessions.shutdown(), remainedInvisible,
                marketplace.sessions.processIdentifiers.isEmpty,
                previousUI?.isRunning != true
            else { throw HostWorkerError.stillRunning }
            let lease = try PackageFileLock(
                url: marketplace.packageStore.leaseURL(for: package), exclusive: true)
            lease.close()
            let result: [String: Any] = [
                "outcome": "passed", "verifiedCarrierCheckIn": true,
                "approvalRequired": approvalRequired,
                "readonlyControlVerified": !approvalRequired && !rejectsRetained
                    && !cleansUnconnected,
                "unconnectedCleanupVerified": cleansUnconnected,
                "staleCandidateRejectedBeforeNativeLoad": rejectsRetained,
                "packageLeaseReleased": true, "verifiedUIExit": true,
                "noEngineWorkers": true, "noVisibleWindows": remainedInvisible,
                "selectedVersion": package.version,
                "rejectedRetainedCandidates": rejectedRetainedCandidates,
                "verifiedRejectedUIExit": verifiedRejectedUIExit,
            ]
            try JSONSerialization.data(withJSONObject: result, options: .sortedKeys).write(
                to: directory.appendingPathComponent("result-registration.json"), options: .atomic)
            NSApp.terminate(nil)
        } catch {
            try? JSONSerialization.data(withJSONObject: [
                "outcome": "failed", "error": String(describing: error),
                "identities": manager.fixtureIdentities,
            ]).write(
                to: directory.appendingPathComponent("result-registration.json"), options: .atomic)
            remote?.configuration = nil
            if let remote { root.dismiss(remote) }
            remote = nil
            window?.close()
            window = nil
            _ = await marketplace.sessions.shutdown()
            NSApp.terminate(nil)
        }
    }

    private func verifyUnconnectedCleanup() async throws {
        for operation in ["close", "disable", "deadline"] {
            let request = EdithHostCore.HostExtensionContentRequest(
                extensionID: "sample", location: "settings", section: "extension")
            let handle = try await manager.scene(for: request)
            guard handle.processIdentity == nil, !handle.isPresented,
                manager.presentationCounts()["sample"] == 1,
                marketplace.sessions.processIdentifiers.isEmpty
            else { throw HostWorkerError.invalidResponse }
            switch operation {
            case "close": try await manager.endPresentation(id: request.presentationID)
            case "disable": try await marketplace.sessions.disable(id: "sample", remember: false)
            default:
                let until = ContinuousClock.now + .seconds(23)
                while manager.presentationCounts()["sample"] != nil, ContinuousClock.now < until {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            guard manager.presentationCounts().isEmpty,
                !HostRemoteSession.extensionIDs.contains("sample"),
                handle.processIdentity == nil, !handle.isPresented,
                marketplace.sessions.processIdentifiers.isEmpty
            else { throw HostWorkerError.invalidResponse }
            do {
                try await handle.update(compact: false, visible: false, width: 500)
                throw HostWorkerError.invalidResponse
            } catch HostWorkerError.rejected {}
            let lease = try PackageFileLock(
                url: marketplace.packageStore.leaseURL(for: package), exclusive: true)
            lease.close()
        }
    }

    private func attachRegistration(_ handle: HostRemoteSceneHandle) {
        activation?.cancel()
        activation = nil
        if let remote {
            remote.delegate = nil
            remote.configuration = nil
            root.dismiss(remote)
        }
        let controller = EXHostViewController()
        controller.delegate = self
        controller.configuration = .init(
            appExtension: handle.identity, sceneID: handle.sceneIdentifier)
        controller.view.frame = root.view.bounds
        remote = controller
        phase = "attaching"
        failure = nil
        root.present(controller, animator: HostRemoteOffscreenAnimator())
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
        activation = Task { [weak self] in
            guard let self else { return }
            do {
                try await handle.connect(
                    through: viewController.makeXPCConnection(),
                    compact: false, visible: !registrationOnly, width: 670)
                guard !Task.isCancelled, viewController === remote else { return }
                phase = "active"
                writeState()
            } catch {
                guard !Task.isCancelled, viewController === remote else { return }
                report(error)
            }
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
@MainActor
private final class HostRemoteOffscreenAnimator: NSObject, NSViewControllerPresentationAnimator {
    func animatePresentation(
        of viewController: NSViewController, from presentingViewController: NSViewController
    ) {
        presentingViewController.addChild(viewController)
        viewController.view.frame = presentingViewController.view.bounds
        presentingViewController.view.addSubview(viewController.view)
    }

    func animateDismissal(
        of viewController: NSViewController, from presentingViewController: NSViewController
    ) {
        viewController.view.removeFromSuperview()
        viewController.removeFromParent()
    }
}

#endif
