import AppKit
import Darwin
import EdithHostCore
import EdithExtensionUI
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor
final class HostWorkerApplication {
    private let control: HostWorkerControl
    private var frames = HostWorkerFrames()
    private var runtimes: [ExtensionBundleRuntime] = []
    private var configuration: HostWorkerConfiguration?
    private var window: NSWindow?
    private var parentWatcher: DispatchSourceProcess?
    private var windowObserver: NSObjectProtocol?
    private var resourceObservers: [NSObjectProtocol] = []
    private var stopping = false

    init() throws {
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        control = HostWorkerControl(descriptor: descriptor)
    }

    func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        for (name, registered) in [
            (ExtensionCommandOwnership.registerNotification, true),
            (ExtensionCommandOwnership.releaseNotification, false),
        ] {
            resourceObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { [control] notification in
                    let accept = notification.userInfo?["accept"] as? (Bool) -> Void
                    guard let pid = notification.userInfo?["pid"] as? Int32, pid > 1,
                        pid != getpid()
                    else {
                        accept?(false)
                        return
                    }
                    do {
                        try control.send(HostWorkerProcessGroup(pid: pid, registered: registered))
                        accept?(true)
                    } catch { accept?(false) }
                })
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: ExtensionPresentation.showWindowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.showWindow() }
        }
        let watcher = DispatchSource.makeProcessSource(
            identifier: getppid(), eventMask: .exit, queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        parentWatcher = watcher
        watcher.resume()
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor [weak self] in self?.receive(bytes) }
        }
        NSApplication.shared.run()
    }

    private func receive(_ bytes: Data) {
        guard !stopping else { return }
        guard !bytes.isEmpty else { shutdown(); return }
        do {
            for frame in try frames.append(bytes) {
                let request = try JSONDecoder().decode(HostWorkerRequest.self, from: frame)
                let response: HostWorkerResponse
                do {
                    try execute(request)
                    response = HostWorkerResponse(
                        token: request.token, ok: true, version: configuration?.version)
                } catch {
                    response = HostWorkerResponse(
                        token: request.token, ok: false,
                        message: "The extension could not complete this action.")
                }
                try control.send(response)
                if request.operation == "stop" { shutdown(); return }
                if !response.ok, request.operation == "start" { shutdown(); return }
            }
        } catch { shutdown() }
    }

    private func execute(_ request: HostWorkerRequest) throws {
        if request.operation == "start" {
            guard configuration == nil, let next = request.configuration,
                next.identifier == Bundle.main.bundleIdentifier
            else { throw HostWorkerError.rejected }
            let identity = try next.identity()
            guard try HostIndex.bundled().contains(where: { $0.id == next.extensionID }) else {
                throw HostWorkerError.rejected
            }
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            guard
                let package = try store.installedPackages().first(where: {
                    $0.id == next.extensionID && $0.hostABI == HostContract.compatibility
                        && $0.architecture == "arm64" && $0.version == next.version
                })
            else { throw HostWorkerError.rejected }
            let directory = store.directory(for: package).appendingPathComponent(package.id)
            let team = ExtensionCodeSignature.teamIdentifier()
            guard identity.development || team != nil else {
                throw MarketplaceError.invalidSignature
            }
            configuration = next
            try applyAppearance(next)
            let context: NSDictionary = [
                "defaultsSuite": identity.extensionDefaultsSuite(package.id),
                "dataDirectory": identity.extensionDirectory(package.id).path,
                "hostIdentifier": identity.identifier,
            ]
            for role in [ExtensionBundleRuntime.Role.helper, .agent, .app] {
                guard
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("\(role.rawValue).bundle").path)
                else { continue }
                let runtime = ExtensionBundleRuntime(
                    store: store, role: role, hostABI: HostContract.compatibility,
                    packageVersion: next.version,
                    verify: { url in
                        if identity.development {
                            try ExtensionCodeSignature.verifyDevelopment(url)
                        } else {
                            guard let team else { throw MarketplaceError.invalidSignature }
                            try ExtensionCodeSignature.verify(url, teamIdentifier: team)
                        }
                    })
                runtimes.append(runtime)
                try runtime.start(id: package.id, context: context)
            }
            guard !runtimes.isEmpty else { throw HostWorkerError.rejected }
            return
        }
        guard let configuration else { throw HostWorkerError.rejected }
        switch request.operation {
        case "show": try showWindow()
        case "synchronize":
            if let next = request.configuration {
                guard next.identifier == configuration.identifier,
                    next.extensionID == configuration.extensionID,
                    next.version == configuration.version
                else { throw HostWorkerError.rejected }
                try applyAppearance(next)
            }
            for runtime in runtimes {
                try runtime.synchronize(id: configuration.extensionID, context: [:])
            }
        case "status":
            for runtime in runtimes {
                guard try runtime.snapshot(id: configuration.extensionID)?.active == true else {
                    throw HostWorkerError.rejected
                }
            }
        case "stop":
            for runtime in runtimes { try runtime.stopAll() }
        default:
            throw HostWorkerError.rejected
        }
    }

    private func showWindow() throws {
        guard !stopping, let configuration else { throw HostWorkerError.rejected }
        if let window {
            window.makeKeyAndOrderFront(nil);
            NSApplication.shared.activate(ignoringOtherApps: true); return
        }
        let identity = try configuration.identity()
        let context: NSDictionary = [
            "defaultsSuite": identity.extensionDefaultsSuite(configuration.extensionID),
            "dataDirectory": identity.extensionDirectory(configuration.extensionID).path,
        ]
        for runtime in runtimes {
            if let controller = try runtime.viewController(
                id: configuration.extensionID, context: context)
            {
                let window = NSWindow(contentViewController: controller)
                window.title =
                    try HostIndex.bundled().first { $0.id == configuration.extensionID }?.title
                    ?? "Edith"
                window.setContentSize(NSSize(width: 900, height: 650))
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.isReleasedWhenClosed = false
                window.center()
                self.window = window
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            }
        }
        throw HostWorkerError.rejected
    }

    private func shutdown() {
        guard !stopping else { return }
        stopping = true
        FileHandle.standardInput.readabilityHandler = nil
        parentWatcher?.cancel()
        parentWatcher = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        resourceObservers.forEach(NotificationCenter.default.removeObserver)
        resourceObservers.removeAll()
        for runtime in runtimes { try? runtime.stopAll() }
        window?.close()
        try? control.close()
        exit(0)
    }

    private func applyAppearance(_ configuration: HostWorkerConfiguration) throws {
        let identity = try configuration.identity()
        guard
            let defaults = UserDefaults(
                suiteName: identity.extensionDefaultsSuite(configuration.extensionID))
        else { throw HostWorkerError.rejected }
        defaults.set(configuration.theme, forKey: "theme")
        defaults.set(configuration.appearance, forKey: "appearance")
        defaults.set(configuration.zoom, forKey: "mainWindowZoom")
        UIScale.apply(configuration.zoom)
        EdithExtensionUI.applyAppearance(configuration.appearance)
    }
}
