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
    private var navigation: HostWorkerNavigationClient?
    private var parentWatcher: DispatchSourceProcess?
    private var windowObserver: NSObjectProtocol?
    private let nativeAdmission = ExtensionNativeTaskAdmission()
    private var resourceObservers: [NSObjectProtocol] = []
    private var stopping = false
    private var preparingDisable = false
    private var preparedApplicationQuit = false
    private var peerServer: ExtensionPeerServer?
    private var shutdownTask: Task<Void, Never>?

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
                        guard let identity = ExtensionProcessIdentity.read(pid) else {
                            accept?(false)
                            return
                        }
                        try control.send(
                            HostWorkerProcessGroup(
                                pid: pid, generation: identity.generation, registered: registered))
                        accept?(true)
                    } catch { accept?(false) }
                })
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: ExtensionPresentation.showWindowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in try? await self?.showWindow() }
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
                if request.operation == "navigationReply" {
                    guard let reply = request.navigation, reply.token == request.token,
                        let navigation
                    else { throw HostWorkerError.invalidResponse }
                    try navigation.receive(reply)
                    continue
                }
                if request.operation == "show" {
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await showWindow()
                            try control.send(
                                HostWorkerResponse(
                                    token: request.token, ok: true, version: configuration?.version)
                            )
                        } catch {
                            try? control.send(HostWorkerResponse(token: request.token, ok: false))
                        }
                    }
                    continue
                }
                if request.operation == "prepareDisable" {
                    prepareDisable(request)
                    continue
                }
                if request.operation == "prepareApplicationQuit" {
                    prepareApplicationQuit(request)
                    continue
                }
                if request.operation == "stop" {
                    shutdown(token: request.token, reason: request.stopReason ?? .shutdown)
                    return
                }
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
                if !response.ok, request.operation == "start" { shutdown(); return }
            }
        } catch { shutdown() }
    }

    private func prepareDisable(_ request: HostWorkerRequest) {
        guard !preparingDisable else {
            try? control.send(
                HostWorkerResponse(
                    token: request.token, ok: false,
                    message: "The extension is still restoring system settings. Wait and try again."
                ))
            return
        }
        preparingDisable = true
        navigation?.cancelPending()
        Task { [self] in
            defer { preparingDisable = false }
            do {
                for runtime in runtimes { try await runtime.prepareDisableAll() }
                try control.send(
                    HostWorkerResponse(
                        token: request.token, ok: true, version: configuration?.version))
            } catch {
                let text = error.localizedDescription
                let message =
                    text.isEmpty || text.count > 1024
                    ? "The extension could not restore its system settings. Open the extension and try again."
                    : text
                try? control.send(
                    HostWorkerResponse(token: request.token, ok: false, message: message))
            }
        }
    }

    private func prepareApplicationQuit(_ request: HostWorkerRequest) {
        guard !preparingDisable, !preparedApplicationQuit,
            request.stopReason == .applicationQuit, let configuration,
            configuration.extensionID == "lidAwake", !configuration.recoveryOnly,
            let engine = runtimes.first(where: { $0.role == .app })
        else {
            try? control.send(HostWorkerResponse(token: request.token, ok: false))
            return
        }
        preparingDisable = true
        navigation?.cancelPending()
        peerServer?.shutdown()
        peerServer = nil
        Task { [self] in
            defer { preparingDisable = false }
            do {
                guard let host = ExtensionProcessIdentity.read(getppid()) else {
                    throw HostWorkerError.rejected
                }
                let response = try engine.response(
                    id: configuration.extensionID, operation: "prepareApplicationQuit",
                    context: [
                        "reason": HostWorkerStopReason.applicationQuit.rawValue,
                        "hostPID": host.pid, "hostGeneration": host.generation,
                    ])
                guard response["ok"] as? Bool == true else { throw HostWorkerError.rejected }
                for runtime in runtimes where runtime !== engine {
                    try await runtime.prepareDisableAll()
                }
                try await engine.prepareToStopAll()
                guard !stopping, host.isAlive else { throw HostWorkerError.rejected }
                preparedApplicationQuit = true
                try control.send(
                    HostWorkerResponse(
                        token: request.token, ok: true, version: configuration.version))
            } catch {
                try? control.send(
                    HostWorkerResponse(
                        token: request.token, ok: false,
                        message:
                            "The extension could not finish its quit policy. Restore settings and try again."
                    ))
            }
        }
    }

    private func execute(_ request: HostWorkerRequest) throws {
        if request.operation == "start" {
            guard configuration == nil, let next = request.configuration,
                next.identifier == Bundle.main.bundleIdentifier
            else { throw HostWorkerError.rejected }
            try next.ambientPolicy.validate(owner: next.extensionID)
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
            let team = ExtensionCodeSignature.teamIdentifier()
            guard identity.development || team != nil else {
                throw MarketplaceError.invalidSignature
            }
            configuration = next
            let navigation = HostFolderChoiceNavigationClient(
                configuration: next,
                available: { [weak self] in
                    guard let self else { return false }
                    return !self.stopping && !self.preparingDisable
                },
                send: { [control] request in try control.send(request) },
                cancel: { [control] request in try control.send(request) })
            self.navigation = navigation
            setenv(
                "EDITH_EXTENSION_NATIVE_CONTEXT",
                try JSONEncoder().encode(next).base64EncodedString(), 1)
            setenv("EDITH_EXTENSION_NATIVE_PARENT", String(getpid()), 1)
            setenv("EDITH_EXTENSION_NATIVE_TOKEN", nativeAdmission.token, 1)
            try applyAppearance(next)
            var values: [String: Any] = [
                "defaultsSuite": identity.extensionDefaultsSuite(package.id),
                "dataDirectory": identity.extensionDirectory(package.id).path,
                "hostIdentifier": identity.identifier,
                "recoveryOnly": next.recoveryOnly, "hostNavigation": navigation,
            ]
            if let launcher = try next.publicLauncherContext(teamIdentifier: team) {
                values["publicLauncher"] = launcher
            }
            for (key, value) in try next.ambientPolicy.context(owner: next.extensionID) {
                guard let key = key as? String else { throw HostWorkerError.rejected }
                values[key] = value
            }
            let context = values as NSDictionary
            for role in [ExtensionBundleRuntime.Role.helper, .agent, .app] {
                guard
                    FileManager.default.fileExists(
                        atPath: store.roleBundle(for: package, role: role).path)
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
            if next.recoveryOnly { return }
            let endpoint = try ExtensionPeerEndpoint(
                namespace: identity.identifier, owner: package.id,
                directory: identity.root.appendingPathComponent("ExtensionState/Commands"))
            let server = ExtensionPeerServer(endpoint: endpoint) {
                [weak self] token, command, payload in
                guard let self, !self.stopping else { throw ExtensionPeerError.unavailable }
                if command == "extension.native.authorize" {
                    guard !self.preparingDisable, payload.count <= 512,
                        let object = try JSONSerialization.jsonObject(with: payload)
                            as? [String: Any],
                        Set(object.keys) == ["pid", "token"], let pid = object["pid"] as? Int32,
                        let capability = object["token"] as? String,
                        self.runtimes.contains(where: {
                            $0.role == .app && (try? $0.snapshot(id: package.id)?.active) == true
                        }),
                        UserDefaults(suiteName: identity.defaultsSuite)?.stringArray(
                            forKey: HostExtensionSessions.enabledExtensionsKey)?.contains(
                                package.id) == true
                    else { throw ExtensionPeerError.unavailable }
                    try self.nativeAdmission.authorize(pid, token: capability)
                    return try JSONEncoder().encode(next)
                }
                if command == "extension.process.register" {
                    guard payload.count <= 128,
                        let object = try JSONSerialization.jsonObject(with: payload)
                            as? [String: Any],
                        Set(object.keys) == ["pid"], let pid = object["pid"] as? Int32
                    else { throw ExtensionPeerError.invalidRequest }
                    try self.nativeAdmission.registerDescendant(pid)
                    return Data("{\"registered\":true}".utf8)
                }
                if command == "surface.context" {
                    guard payload.isEmpty, let context = SurfaceHostContext.current else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    return try JSONEncoder().encode(SurfaceContextSnapshot(context))
                }
                if command == "extension.open" {
                    guard payload.isEmpty else { throw ExtensionPeerError.invalidRequest }
                    try await self.showWindow()
                    return Data("{\"opened\":true}".utf8)
                }
                guard
                    let runtime = self.runtimes.first(where: {
                        $0.supportsCommands(id: package.id)
                    })
                else {
                    throw ExtensionPeerError.rejected(
                        "This extension does not support that command.")
                }
                return try await runtime.command(
                    id: package.id, token: token, command: command, payload: payload)
            }
            peerServer = server
            try server.start()
            return
        }
        guard let configuration else { throw HostWorkerError.rejected }
        switch request.operation {
        case "synchronize", "ambientPolicy":
            guard let route = HostWorkerSynchronization(rawValue: request.operation) else {
                throw HostWorkerError.rejected
            }
            self.configuration = try route.apply(
                request, current: configuration,
                appearance: { try self.applyAppearance($0) },
                synchronize: { id, context in
                    for runtime in self.runtimes {
                        try runtime.synchronize(id: id, context: context)
                    }
                })
        case "status":
            for runtime in runtimes {
                guard try runtime.snapshot(id: configuration.extensionID)?.active == true else {
                    throw HostWorkerError.rejected
                }
            }
        default:
            throw HostWorkerError.rejected
        }
    }

    private func showWindow() async throws {
        guard !stopping, !preparingDisable, let configuration, !configuration.recoveryOnly else {
            throw HostWorkerError.rejected
        }
        guard let navigation else { throw HostWorkerError.rejected }
        try await navigation.request()
    }

    private func shutdown(token: UUID? = nil, reason: HostWorkerStopReason = .ownerLost) {
        guard !stopping else { return }
        stopping = true
        navigation?.invalidate()
        peerServer?.shutdown()
        peerServer = nil
        FileHandle.standardInput.readabilityHandler = nil
        parentWatcher?.cancel()
        parentWatcher = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        resourceObservers.forEach(NotificationCenter.default.removeObserver)
        resourceObservers.removeAll()
        shutdownTask = Task { [self] in
            if reason != .applicationQuit || !preparedApplicationQuit {
                for runtime in runtimes { try? await runtime.prepareDisableAll() }
            }
            for runtime in runtimes { try? await runtime.prepareToStopAll() }
            for runtime in runtimes { try? runtime.stopAll() }
            if let token {
                try? control.send(
                    HostWorkerResponse(token: token, ok: true, version: configuration?.version))
            }
            try? control.close()
            exit(0)
        }
    }

    private func applyAppearance(_ configuration: HostWorkerConfiguration) throws {
        let identity = try configuration.identity()
        guard
            let defaults = UserDefaults(
                suiteName: identity.extensionDefaultsSuite(configuration.extensionID))
        else { throw HostWorkerError.rejected }
        defaults.set(configuration.theme, forKey: AppStorageKeys.General.theme)
        defaults.set(configuration.appearance, forKey: AppStorageKeys.General.appearance)
        defaults.set(configuration.zoom, forKey: AppStorageKeys.General.mainWindowZoom)
        UIScale.apply(configuration.zoom)
        EdithExtensionUI.applyAppearance(configuration.appearance)
    }
}
