import AppKit
import Darwin
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor
public final class HostInProcessWorkerEngine: HostWorkerEngine {
    private let channel: HostWorkerChannel
    private var runtimes: [ExtensionBundleRuntime] = []
    private var configuration: HostWorkerConfiguration?
    private var navigation: HostWorkerNavigationClient?
    private var observers: [NSObjectProtocol] = []
    private let nativeAdmission = ExtensionNativeTaskAdmission()
    private var stopping = false
    private let preparation = HostWorkerPreparation()
    private var preparingDisable: Bool { preparation.isClosed }
    private var preparedApplicationQuit = false
    private var peerServer: ExtensionPeerServer?

    public init(channel: HostWorkerChannel) {
        self.channel = channel
    }

    public func deliver(_ reply: HostWorkerNavigationReply) throws {
        guard let navigation else { throw HostWorkerError.invalidResponse }
        try navigation.receive(reply)
    }

    public func perform(_ request: HostWorkerRequest) async -> HostWorkerResponse {
        let version = configuration?.version
        guard !stopping else { return HostWorkerResponse(token: request.token, ok: false) }
        switch request.operation {
        case "show":
            do {
                try await showWindow()
                return HostWorkerResponse(token: request.token, ok: true, version: version)
            } catch { return HostWorkerResponse(token: request.token, ok: false) }
        case "quitStatus":
            let prevents = runtimes.contains { runtime in
                guard runtime.role == .app, let id = configuration?.extensionID else {
                    return false
                }
                let status = try? runtime.response(id: id, operation: "status")
                return status?["preventsQuit"] as? Bool == true
            }
            return HostWorkerResponse(
                token: request.token, ok: true, version: version,
                message: prevents ? HostWorkerResponse.preventsQuitMessage : nil)
        case "prepareDisable":
            return await prepareDisable(request)
        case "prepareApplicationQuit":
            return await prepareApplicationQuit(request)
        case "stop":
            let failure = await shutdown(reason: request.stopReason ?? .shutdown)
            return HostWorkerResponse(token: request.token, ok: failure == nil, version: version)
        default:
            do {
                try execute(request)
                return HostWorkerResponse(
                    token: request.token, ok: true, version: configuration?.version)
            } catch {
                if request.operation == "start" {
                    NSLog(
                        "Edith could not start %@: %@",
                        request.configuration?.extensionID ?? "an extension", "\(error)")
                    _ = await shutdown(reason: .shutdown)
                }
                return HostWorkerResponse(
                    token: request.token, ok: false,
                    message: request.operation == "start"
                        ? String(
                            ((error as? LocalizedError)?.errorDescription
                                ?? "The extension could not finish starting.").prefix(1024))
                        : "The extension could not complete this action.")
            }
        }
    }

    private func prepareDisable(_ request: HostWorkerRequest) async -> HostWorkerResponse {
        navigation?.cancelPending()
        do {
            try await preparation.begin(token: request.token) {
                self.peerServer?.closeMutationAdmission()
                for runtime in self.runtimes { try await runtime.suspendCommandsAll() }
                await self.peerServer?.cancelAndJoinRequests()
                for runtime in self.runtimes { try await runtime.prepareDisableAll() }
            }.value.get()
            return HostWorkerResponse(
                token: request.token, ok: true, version: configuration?.version)
        } catch {
            let text = error.localizedDescription
            let message =
                text.isEmpty || text.count > 1024
                ? "The extension could not restore its system settings. Open the extension and try again."
                : text
            return HostWorkerResponse(token: request.token, ok: false, message: message)
        }
    }

    private func prepareApplicationQuit(_ request: HostWorkerRequest) async -> HostWorkerResponse {
        guard request.stopReason == .applicationQuit, let configuration,
            configuration.extensionID == "lidAwake", !configuration.recoveryOnly,
            let engine = runtimes.first(where: { $0.role == .app }),
            let host = ExtensionProcessIdentity.read(getpid())
        else { return HostWorkerResponse(token: request.token, ok: false) }
        navigation?.cancelPending()
        let retiringServer = peerServer
        retiringServer?.shutdown()
        do {
            try await preparation.begin(token: request.token, operation: "applicationQuit") {
                for runtime in self.runtimes { try await runtime.suspendCommandsAll() }
                await retiringServer?.shutdownAndWait()
                if self.peerServer === retiringServer { self.peerServer = nil }
                let response = try engine.response(
                    id: configuration.extensionID, operation: "prepareApplicationQuit",
                    context: [
                        "reason": HostWorkerStopReason.applicationQuit.rawValue,
                        "hostPID": host.pid, "hostGeneration": host.generation,
                    ])
                guard response["ok"] as? Bool == true else { throw HostWorkerError.rejected }
                for runtime in self.runtimes where runtime !== engine {
                    try await runtime.prepareDisableAll()
                }
                try await engine.prepareToStopAll()
                guard !self.stopping else { throw HostWorkerError.rejected }
                self.preparedApplicationQuit = true
            }.value.get()
            return HostWorkerResponse(
                token: request.token, ok: true, version: configuration.version)
        } catch {
            return HostWorkerResponse(
                token: request.token, ok: false,
                message:
                    "The extension could not finish its quit policy. Restore settings and try again."
            )
        }
    }

    private func execute(_ request: HostWorkerRequest) throws {
        guard !preparingDisable || request.operation == "status" else {
            throw HostWorkerError.rejected
        }
        if request.operation == "start" {
            try start(request)
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

    private func start(_ request: HostWorkerRequest) throws {
        guard configuration == nil, let next = request.configuration,
            next.identifier == Bundle.main.bundleIdentifier
        else { throw HostWorkerError.rejected }
        try next.ambientPolicy.validate(owner: next.extensionID)
        let identity = try next.identity()
        guard try HostIndex.bundled().contains(where: { $0.id == next.extensionID }) else {
            throw HostWorkerError.rejected
        }
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        guard
            let package = try store.installedPackages().first(where: {
                $0.id == next.extensionID && $0.hostABI == HostContract.compatibility
                    && $0.architecture == "arm64" && $0.version == next.version
            })
        else { throw HostWorkerError.rejected }
        let team = ExtensionCodeSignature.teamIdentifier()
        guard identity.development || team != nil else { throw MarketplaceError.invalidSignature }
        let channel = channel
        let navigation = HostFolderChoiceNavigationClient(
            configuration: next,
            available: { [weak self] in
                guard let self else { return false }
                return !self.stopping && !self.preparingDisable
            },
            send: { try channel.navigate($0) },
            cancel: { try channel.cancelNavigation($0) })
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
        let verify: (URL) throws -> Void = { url in
            if identity.development {
                try ExtensionCodeSignature.verifyDevelopment(url)
            } else {
                guard let team else { throw MarketplaceError.invalidSignature }
                try ExtensionCodeSignature.verify(url, teamIdentifier: team)
            }
        }
        let roles = [ExtensionBundleRuntime.Role.helper, .agent, .app].filter {
            FileManager.default.fileExists(atPath: store.roleBundle(for: package, role: $0).path)
        }
        guard !roles.isEmpty else { throw HostWorkerError.rejected }
        var environment = try next.extensionEnvironment()
        environment["EDITH_EXTENSION_NATIVE_CONTEXT"] = try JSONEncoder().encode(next)
            .base64EncodedString()
        environment["EDITH_EXTENSION_NATIVE_PARENT"] = String(getpid())
        environment["EDITH_EXTENSION_NATIVE_TOKEN"] = nativeAdmission.token
        configuration = next
        self.navigation = navigation
        try applyAppearance(next)
        observe(owner: package.id)
        for role in roles {
            let runtime = ExtensionBundleRuntime(
                store: store, role: role, hostABI: HostContract.compatibility,
                packageVersion: next.version, environment: environment, verify: verify)
            runtimes.append(runtime)
            try runtime.start(id: package.id, context: context)
        }
        if next.recoveryOnly { return }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: identity.identifier, owner: package.id,
            directory: identity.root.appendingPathComponent("ExtensionState/Commands"))
        let server = ExtensionPeerServer(
            endpoint: endpoint,
            controlsDuringDrain: ["extension.process.register", "surface.context"]
        ) { [weak self] token, command, payload in
            guard let self else { throw ExtensionPeerError.unavailable }
            return try await self.peerCommand(
                token: token, command: command, payload: payload, package: package,
                identity: identity, configuration: next)
        }
        peerServer = server
        try server.start()
    }

    private func peerCommand(
        token: UUID, command: String, payload: Data, package: ExtensionPackage,
        identity: HostIdentity, configuration next: HostWorkerConfiguration
    ) async throws -> Data {
        if command == "extension.process.register" {
            guard payload.count <= 128,
                let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                Set(object.keys) == ["pid"], let pid = object["pid"] as? Int32
            else { throw ExtensionPeerError.invalidRequest }
            try nativeAdmission.registerDescendant(pid)
            return Data("{\"registered\":true}".utf8)
        }
        guard !stopping else { throw ExtensionPeerError.unavailable }
        if command == "extension.native.authorize" {
            guard !preparingDisable, payload.count <= 512,
                let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                Set(object.keys) == ["pid", "token"], let pid = object["pid"] as? Int32,
                let capability = object["token"] as? String,
                runtimes.contains(where: {
                    $0.role == .app && (try? $0.snapshot(id: package.id)?.active) == true
                }),
                UserDefaults(suiteName: identity.defaultsSuite)?.stringArray(
                    forKey: HostExtensionSessions.enabledExtensionsKey)?.contains(package.id)
                    == true
            else { throw ExtensionPeerError.unavailable }
            try nativeAdmission.authorize(pid, token: capability)
            return try JSONEncoder().encode(next)
        }
        if command == "surface.context" {
            guard payload.isEmpty, let context = SurfaceHostContext.current else {
                throw ExtensionPeerError.invalidRequest
            }
            return try JSONEncoder().encode(SurfaceContextSnapshot(context))
        }
        if command == "extension.open" {
            guard payload.isEmpty else { throw ExtensionPeerError.invalidRequest }
            try await showWindow()
            return Data("{\"opened\":true}".utf8)
        }
        guard !preparingDisable else { throw ExtensionPeerError.unavailable }
        guard let runtime = runtimes.first(where: { $0.supportsCommands(id: package.id) }) else {
            throw ExtensionPeerError.rejected("This extension does not support that command.")
        }
        return try await runtime.command(
            id: package.id, token: token, command: command, payload: payload)
    }

    func observe(owner: String) {
        let channel = channel
        for (name, registered) in [
            (ExtensionCommandOwnership.registerNotification, true),
            (ExtensionCommandOwnership.releaseNotification, false),
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    notification in
                    guard notification.userInfo?["owner"] as? String == owner else { return }
                    nonisolated(unsafe) let accept =
                        notification.userInfo?["accept"] as? (Bool) -> Void
                    guard let pid = notification.userInfo?["pid"] as? Int32, pid > 1,
                        pid != getpid(), let identity = ExtensionProcessIdentity.read(pid)
                    else {
                        accept?(false)
                        return
                    }
                    let resource = HostWorkerProcessGroup(
                        pid: pid, generation: identity.generation, registered: registered)
                    MainActor.assumeIsolated {
                        do {
                            try channel.processGroup(resource)
                            accept?(true)
                        } catch { accept?(false) }
                    }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: ExtensionWindowRequest.notification, object: nil, queue: .main
            ) { [weak self] notification in
                guard notification.userInfo?["owner"] as? String == owner else { return }
                Task { @MainActor [weak self] in try? await self?.showWindow() }
            })
    }

    private func showWindow() async throws {
        guard !stopping, !preparingDisable, let configuration, !configuration.recoveryOnly,
            let navigation
        else { throw HostWorkerError.rejected }
        try await navigation.request()
    }

    private func shutdown(reason: HostWorkerStopReason) async -> Error? {
        guard !stopping else { return nil }
        stopping = true
        navigation?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        var failure: Error?
        if reason == .applicationQuit, !preparation.isClosed {
            let runtimes = runtimes
            _ = await HostDeadline.run(.milliseconds(400)) {
                for runtime in runtimes { try? await runtime.prepareToStopAll() }
            }
        } else {
            do {
                if preparation.isClosed {
                    try await preparation.join()
                } else {
                    try await preparation.prepare {
                        for runtime in self.runtimes { try await runtime.suspendCommandsAll() }
                        for runtime in self.runtimes { try await runtime.prepareDisableAll() }
                    }
                }
            } catch { failure = error }
            for runtime in runtimes {
                do { try await runtime.prepareToStopAll() } catch { failure = error }
            }
        }
        if reason == .applicationQuit {
            peerServer?.shutdown()
        } else {
            await peerServer?.shutdownAndWait()
        }
        peerServer = nil
        for runtime in runtimes {
            do { try runtime.stopAll() } catch { failure = error }
        }
        runtimes.removeAll()
        return failure
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
    }
}

@MainActor
enum HostDeadline {
    static func run(_ limit: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool
    {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish: @MainActor (Bool) -> Void = { completed in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: completed)
            }
            Task { @MainActor in
                await work()
                finish(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                finish(false)
            }
        }
    }
}
