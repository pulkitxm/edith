import AppKit
import Darwin
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionFoundation
import ExtensionKit
import ExtensionMarketplace
import SwiftUI

@MainActor
final class HostRemoteApplication {
    #if EDITH_FUNCTIONAL_FIXTURE
    struct FixtureStopPreparation {
        let token: UUID
        let configuration: HostRemoteConfiguration?
        let roles: [String]
        let presentations: [UUID]
    }
    static var fixtureObserveStopPreparation: ((FixtureStopPreparation) throws -> Void)?
    static var fixtureObserveCommandRetirement: ((UUID) throws -> Void)?
    private var fixtureRetirementObserver: NSObjectProtocol?
    private var fixtureRetirementFailure: Error?
    static var fixtureAdmitConfiguration: ((HostRemoteConfiguration) async throws -> Void)?
    static var fixtureAdmitBeforeConstruction:
        (
            (HostRemoteConfiguration, HostRemotePresentation, NSDictionary, [URL]) throws ->
                [HostFixtureRoleAdmission]
        )?
    #endif
    static let shared: HostRemoteApplication = {
        do { return try HostRemoteApplication() } catch {
            exit(1)
        }
    }()

    private let hostIdentifier: String
    private let extensionID: String
    private let version: String
    private let payload: URL
    private var endpoint: HostRemoteEndpoint!
    private var slots: [HostRemoteSceneSlot] = []
    private var configuration: HostRemoteConfiguration?
    private var runtimes: [ExtensionBundleRuntime] = []
    private var presentationRuntimes: [UUID: ExtensionBundleRuntime] = [:]
    private var terminalRenderer = HostRemoteTerminalRenderer()
    private var stopping = false
    private let stopPreparation = HostWorkerPreparation()
    private var exitScheduled = false
    private var exitTask: Task<Void, Never>?

    private init() throws {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "appex",
            let hostIdentifier = bundle.object(forInfoDictionaryKey: "EdithHostIdentifier")
                as? String,
            let extensionID = bundle.object(forInfoDictionaryKey: "EdithExtensionID") as? String,
            let version = bundle.object(forInfoDictionaryKey: "EdithExtensionVersion") as? String,
            bundle.bundleIdentifier == hostIdentifier + ".extension." + extensionID + ".worker",
            bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String
                == HostContract.compatibility,
            bundle.object(forInfoDictionaryKey: "EdithPayloadRelativePath") as? String
                == "Contents/Resources/Payload",
            let executable = bundle.object(forInfoDictionaryKey: "EdithHostExecutablePath")
                as? String,
            executable.hasPrefix("/"), !executable.utf8.contains(0), executable.utf8.count <= 4096,
            let requirement = bundle.object(forInfoDictionaryKey: "EdithHostCodeRequirement")
                as? String,
            !extensionID.isEmpty, extensionID.utf8.count <= 80,
            extensionID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { throw HostWorkerError.rejected }
        self.hostIdentifier = hostIdentifier
        self.extensionID = extensionID
        self.version = version
        payload = bundle.bundleURL.appendingPathComponent("Contents/Resources/Payload")
        #if EDITH_FUNCTIONAL_FIXTURE
        fixtureRetirementObserver = NotificationCenter.default.addObserver(
            forName: ExtensionCommandRegistry.ownerJoinedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let value = notification.userInfo?["token"] as? String,
                let token = UUID(uuidString: value)
            else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    guard let observe = Self.fixtureObserveCommandRetirement else {
                        throw HostWorkerError.rejected
                    }
                    try observe(token)
                } catch {
                    self.fixtureRetirementFailure = error
                    self.shutdown()
                }
            }
        }
        #endif
        let hostExecutable = URL(fileURLWithPath: executable)
        if hostIdentifier == "com.pulkit.edith",
            executable != "/Applications/Edith.app/Contents/MacOS/Edith"
        {
            throw HostWorkerError.rejected
        }
        endpoint = try HostRemoteEndpoint(
            executable: hostExecutable, requirement: requirement,
            execute: { [weak self] command in
                guard let self else { throw HostWorkerError.exited }
                return try await self.execute(command)
            }, didDisconnect: { [weak self] in self?.shutdown() })
        for index in 0..<HostRemoteSceneDescriptor.maximumScenes {
            slots.append(
                try HostRemoteSceneSlot(
                    index: index, executable: hostExecutable, requirement: requirement,
                    present: { [weak self] context in
                        guard let self else { throw HostWorkerError.exited }
                        return try self.controller(presentation: context)
                    },
                    terminal: { [weak self] request in
                        guard let self else { throw HostWorkerError.exited }
                        return try self.terminal(request)
                    },
                    disconnected: { [weak self] in
                        guard self?.configuration == nil else { return }
                        self?.shutdown()
                    }))
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            if self?.configuration == nil { self?.shutdown() }
        }
    }

    var sceneConfiguration: AppExtensionSceneConfiguration {
        return AppExtensionSceneConfiguration(
            self.slots.map { slot in
                PrimitiveAppExtensionScene(
                    id: slot.identifier,
                    content: { HostRemoteSceneView(slot: slot) },
                    onConnection: { [bootstrap = slot.bootstrap] connection in
                        bootstrap.accept(connection)
                    })
            }, configuration: HostRemoteExtensionConfiguration(endpoint: endpoint))
    }

    private func execute(_ command: HostRemoteCommand) async throws -> Data {
        if command.operation == "stop" {
            try await beginShutdown(token: command.token).value.get()
            scheduleExit()
            return Data()
        }
        guard !stopping else { throw HostWorkerError.exited }
        switch command.operation {
        case "configure":
            guard configuration == nil else { throw HostWorkerError.rejected }
            let next = try HostRemoteWire.decode(
                HostRemoteConfiguration.self, from: command.payload)
            try next.validate(
                hostIdentifier: hostIdentifier, extensionID: extensionID, version: version)
            #if EDITH_FUNCTIONAL_FIXTURE
            guard let admit = Self.fixtureAdmitConfiguration else { throw HostWorkerError.rejected }
            try await admit(next)
            try Task.checkCancellation()
            guard !stopping, configuration == nil else { throw HostWorkerError.rejected }
            #endif
            let suite = Bundle.main.bundleIdentifier!
            setenv("EDITH_APPLICATION_IDENTIFIER", hostIdentifier, 1)
            setenv("EDITH_EXTENSION_ID", extensionID, 1)
            setenv("EDITH_SHARED_DEFAULTS_SUITE", suite, 1)
            let defaults = UserDefaults.standard
            defaults.set(next.worker.theme, forKey: AppStorageKeys.General.theme)
            defaults.set(next.worker.appearance, forKey: AppStorageKeys.General.appearance)
            defaults.set(next.worker.zoom, forKey: AppStorageKeys.General.mainWindowZoom)
            UIScale.apply(next.worker.zoom)
            EdithExtensionUI.applyAppearance(next.worker.appearance)
            configuration = next
            return Data()
        case "reserve":
            guard let configuration else { throw HostWorkerError.rejected }
            let reservation = try HostRemoteWire.decode(
                HostRemoteReservation.self, from: command.payload)
            let request = reservation.request
            let index = try reservation.slot(extensionID: extensionID)
            guard
                !configuration.uiOnly || (request.location == "settings" && request.surface == nil),
                !slots.contains(where: { $0.request?.presentationID == request.presentationID }),
                slots[index].request == nil
            else { throw HostWorkerError.rejected }
            let slot = slots[index]
            try slot.reserve(request, session: configuration.session)
            return try HostRemoteWire.encode(
                HostRemoteSceneDescriptor(slot: slot.index, presentationID: request.presentationID))
        case "flush":
            let id = try HostRemoteWire.decode(UUID.self, from: command.payload)
            guard slots.contains(where: { $0.request?.presentationID == id }) else {
                throw HostWorkerError.rejected
            }
            slots.first { $0.request?.presentationID == id }?.beginClosing()
            for runtime in runtimes {
                try await runtime.preparePresentationToClose(id: extensionID, presentationID: id)
            }
            return Data()
        case "release":
            let id = try HostRemoteWire.decode(UUID.self, from: command.payload)
            guard let slot = slots.first(where: { $0.request?.presentationID == id }) else {
                throw HostWorkerError.rejected
            }
            slot.release()
            presentationRuntimes[id] = nil
            terminalRenderer.release(id)
            for runtime in runtimes {
                _ = try runtime.response(
                    id: extensionID, operation: "releaseUI",
                    context: ["presentationID": id.uuidString])
            }
            return Data()
        default: throw HostWorkerError.rejected
        }
    }

    private func controller(
        presentation: HostRemotePresentation
    ) throws -> ExtensionBundlePresentation {
        guard let configuration, !stopping else { throw HostWorkerError.rejected }
        try presentation.validate(session: configuration.session, extensionID: extensionID)
        let input = NSMutableDictionary(dictionary: [
            "remoteUI": true, "uiOnly": configuration.uiOnly,
            "location": presentation.request.location,
            "presentationID": presentation.request.presentationID.uuidString,
            "defaultsSuite": Bundle.main.bundleIdentifier!, "hostIdentifier": hostIdentifier,
            "extensionID": extensionID,
        ])
        if !configuration.uiOnly {
            guard
                let slot = slots.first(where: {
                    $0.request?.presentationID == presentation.request.presentationID
                }), let endpoint = slot.endpoint
            else { throw HostWorkerError.rejected }
            input["engineClient"] = HostRemoteEngineBridge(
                endpoint: endpoint, presentationID: presentation.request.presentationID)
        }
        input["section"] = presentation.request.section
        if let target = presentation.request.machinesWindow {
            input["target"] = try target.context(
                presentationID: presentation.request.presentationID)
        }
        if let target = presentation.request.herdrWindow {
            input["target"] = target.target
            input["herdrPresentationToken"] = target.token.uuidString
        }
        if let surface = presentation.request.surface {
            input["tile"] = try JSONEncoder().encode(surface.tile)
            input["target"] = surface.target.rawValue
        }
        #if EDITH_FUNCTIONAL_FIXTURE
        guard let admit = Self.fixtureAdmitBeforeConstruction else {
            throw HostWorkerError.rejected
        }
        input["dataDirectory"] = try configuration.worker.identity().extensionDirectory(extensionID)
            .path
        let roles = [ExtensionBundleRuntime.Role.app, .helper, .agent].map {
            payload.appendingPathComponent(extensionID).appendingPathComponent(
                "\($0.rawValue).bundle")
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !roles.isEmpty else { throw HostWorkerError.rejected }
        let admissionContext = input.mutableCopy() as! NSMutableDictionary
        admissionContext["operation"] = "configureUI"
        let admissions = try admit(configuration, presentation, admissionContext, roles)
        try HostFixtureRoleAdmission.validate(
            admissions, available: roles,
            markerKeys: [
                "sourceCommit", "session", "phase", "descriptorPath", "capabilitySHA256",
            ])
        var selectedRuntimes: [(ExtensionBundleRuntime, HostFixtureRoleAdmission)] = []
        let team = ExtensionCodeSignature.teamIdentifier()
        let development = try configuration.worker.identity().development
        for admission in admissions {
            guard
                let role = ExtensionBundleRuntime.Role(
                    rawValue: admission.roleDirectory.deletingPathExtension().lastPathComponent)
            else { throw HostWorkerError.rejected }
            let runtime = try admission.withCurrent {
                if let retained = runtimes.first(where: { $0.role == role }) { return retained }
                let created = try ExtensionBundleRuntime(
                    readOnlyPackage: configuration.package, directory: payload, role: role,
                    hostABI: HostContract.compatibility,
                    verify: { url in
                        if development {
                            try ExtensionCodeSignature.verifyDevelopment(url)
                        } else {
                            guard let team else { throw MarketplaceError.invalidSignature }
                            try ExtensionCodeSignature.verify(url, teamIdentifier: team)
                        }
                    })
                runtimes.append(created)
                return created
            }
            selectedRuntimes.append((runtime, admission))
        }
        #else
        if runtimes.isEmpty {
            let team = ExtensionCodeSignature.teamIdentifier()
            let development = try configuration.worker.identity().development
            for role in [ExtensionBundleRuntime.Role.app, .helper, .agent] {
                let bundle = payload.appendingPathComponent(extensionID).appendingPathComponent(
                    "\(role.rawValue).bundle")
                guard FileManager.default.fileExists(atPath: bundle.path) else { continue }
                runtimes.append(
                    try ExtensionBundleRuntime(
                        readOnlyPackage: configuration.package, directory: payload, role: role,
                        hostABI: HostContract.compatibility,
                        verify: { url in
                            if development {
                                try ExtensionCodeSignature.verifyDevelopment(url)
                            } else {
                                guard let team else { throw MarketplaceError.invalidSignature }
                                try ExtensionCodeSignature.verify(url, teamIdentifier: team)
                            }
                        }))
            }
        }
        #endif
        #if EDITH_FUNCTIONAL_FIXTURE
        for (runtime, admission) in selectedRuntimes {
            input["hostedFunctionalFixture"] = admission.contextMarker
            let result = try admission.withCurrent {
                let response = try runtime.response(
                    id: extensionID, operation: "configureUI", context: input)
                guard response["ok"] as? Bool == true else {
                    return nil as ExtensionBundlePresentation?
                }
                return try runtime.presentation(
                    id: extensionID, context: input, compact: presentation.compact,
                    visible: presentation.visible, width: presentation.availableWidth,
                    intrinsic: !["main", "settings", "music.detail"].contains(
                        presentation.request.location))
            }
            if let result {
                presentationRuntimes[presentation.request.presentationID] = runtime
                return result
            }
        }
        #else
        for runtime in runtimes {
            let response = try runtime.response(
                id: extensionID, operation: "configureUI", context: input)
            guard response["ok"] as? Bool == true else { continue }
            if let result = try runtime.presentation(
                id: extensionID, context: input, compact: presentation.compact,
                visible: presentation.visible, width: presentation.availableWidth,
                intrinsic: !["main", "settings", "music.detail"].contains(
                    presentation.request.location))
            {
                presentationRuntimes[presentation.request.presentationID] = runtime
                return result
            }
        }
        #endif
        throw HostWorkerError.rejected
    }

    private func terminal(_ request: HostTerminalUIRequest) throws -> Data {
        guard !stopping, let configuration, !configuration.uiOnly,
            request.request.extensionID == extensionID,
            HostTerminalUIRequest.accepts(request.request),
            slots.contains(where: { $0.request == request.request }),
            let runtime = presentationRuntimes[request.request.presentationID]
        else { throw HostWorkerError.rejected }
        return try terminalRenderer.response(
            request, session: configuration.session, owner: extensionID,
            configuredRequest: slots.first { $0.request == request.request }?.request
        ) { operation, context in
            try runtime.response(id: extensionID, operation: operation, context: context)
        }
    }

    private func beginShutdown(token: UUID = UUID()) throws -> Task<Result<Void, Error>, Never> {
        stopping = true
        endpoint.closeMutationAdmission()
        let retainedRuntimes = runtimes
        let presentations = slots.compactMap { $0.request?.presentationID }
        slots.forEach { $0.beginClosing() }
        return try stopPreparation.begin(token: token) { [self] in
            await endpoint.prepareToStop(excluding: token)
            for slot in slots { await slot.prepareToStop() }
            for runtime in retainedRuntimes { try await runtime.suspendRemoteUICommandsAll() }
            for runtime in retainedRuntimes {
                for presentationID in presentations {
                    try await runtime.preparePresentationToClose(
                        id: extensionID, presentationID: presentationID)
                }
                try await runtime.prepareRemoteUIToStopAll()
                let response = try runtime.response(id: extensionID, operation: "stopUI")
                guard response["ok"] as? Bool == true else { throw HostWorkerError.rejected }
            }
            #if EDITH_FUNCTIONAL_FIXTURE
            if let failure = fixtureRetirementFailure { throw failure }
            guard let observe = Self.fixtureObserveStopPreparation else {
                throw HostWorkerError.rejected
            }
            try observe(
                FixtureStopPreparation(
                    token: token, configuration: configuration,
                    roles: retainedRuntimes.map { $0.role.rawValue }, presentations: presentations))
            #endif
            slots.forEach { $0.release(reset: false) }
            presentationRuntimes.removeAll()
            terminalRenderer = HostRemoteTerminalRenderer()
        }
    }

    private func shutdown() {
        let cleanup = Result { try beginShutdown() }
        Task { [self] in
            do {
                try await cleanup.get().value.get()
                scheduleExit()
            } catch {}
        }
    }

    private func scheduleExit() {
        guard !exitScheduled else { return }
        exitScheduled = true
        exitTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(50))
            await endpoint.invalidateAndWait()
            for slot in slots { await slot.invalidateAndWait() }
            exit(0)
        }
    }

}

private struct HostRemoteExtensionConfiguration: AppExtensionConfiguration {
    let endpoint: HostRemoteEndpoint
    nonisolated func accept(connection: NSXPCConnection) -> Bool {
        endpoint.acceptBootstrap(connection)
    }
}

@MainActor
private final class HostRemoteSceneSlot {
    let index: Int
    let identifier: String
    var endpoint: HostRemoteEndpoint!
    let bootstrap = HostRemoteSceneBootstrap()
    private(set) var request: EdithHostCore.HostExtensionContentRequest?
    private var session: UUID?
    private var content: ExtensionBundlePresentation?
    private var presentation: HostRemotePresentation?
    weak var container: HostRemoteSceneController?
    private let present: (HostRemotePresentation) throws -> ExtensionBundlePresentation
    private let terminal: (HostTerminalUIRequest) throws -> Data
    private var closing = false
    private let disconnected: @MainActor () -> Void
    private let executable: URL
    private let requirement: String
    private var generation = UUID()
    private var retiringEndpoints: [UUID: Task<Void, Never>] = [:]

    init(
        index: Int, executable: URL, requirement: String,
        present:
            @escaping (HostRemotePresentation) throws -> ExtensionBundlePresentation,
        terminal: @escaping (HostTerminalUIRequest) throws -> Data,
        disconnected: @escaping @MainActor () -> Void
    ) throws {
        self.index = index
        self.executable = executable
        self.requirement = requirement
        identifier = try HostRemoteSceneDescriptor(slot: index, presentationID: UUID())
            .sceneIdentifier
        self.present = present
        self.terminal = terminal
        self.disconnected = disconnected
        try resetEndpoint()
    }

    private func resetEndpoint() throws {
        let generation = generation
        endpoint = try HostRemoteEndpoint(
            executable: executable, requirement: requirement,
            execute: { [weak self] command in
                guard let self, self.generation == generation else { throw HostWorkerError.exited }
                return try self.execute(command)
            },
            didDisconnect: { [weak self] in
                guard let self, self.generation == generation else { return }
                self.clearView()
                self.disconnected()
            })
        bootstrap.replace(endpoint)
    }

    func reserve(_ request: EdithHostCore.HostExtensionContentRequest, session: UUID) throws {
        guard self.request == nil, endpoint != nil else { throw HostWorkerError.rejected }
        self.request = request
        self.session = session
        closing = false
    }

    func beginClosing() {
        closing = true
        endpoint?.closeMutationAdmission()
    }

    func prepareToStop() async {
        beginClosing()
        await endpoint?.prepareToStop()
        for task in retiringEndpoints.values { await task.value }
    }

    func invalidateAndWait() async {
        if let endpoint { await endpoint.invalidateAndWait() }
        for task in retiringEndpoints.values { await task.value }
        retiringEndpoints.removeAll()
    }

    private func execute(_ command: HostRemoteCommand) throws -> Data {
        if HostTerminalUIRequest.Operation(rawValue: command.operation) != nil {
            guard !closing, let request, let session, presentation != nil, content != nil else {
                throw HostWorkerError.rejected
            }
            let input = try HostTerminalUIRequest.decode(
                command.payload, session: session, request: request, operation: command.operation)
            return try terminal(input)
        }
        guard !closing, ["present", "update"].contains(command.operation), let request, let session
        else {
            throw HostWorkerError.rejected
        }
        let context = try HostRemoteWire.decode(HostRemotePresentation.self, from: command.payload)
        try context.validate(session: session, extensionID: request.extensionID)
        guard context.request == request else { throw HostWorkerError.rejected }
        if command.operation == "present" {
            guard presentation == nil, container != nil else { throw HostWorkerError.rejected }
        } else {
            guard presentation != nil else { throw HostWorkerError.rejected }
        }
        try content?.update(
            compact: context.compact, visible: context.visible, width: context.availableWidth,
            intrinsic: !["main", "settings", "music.detail"].contains(request.location))
        presentation = context
        try render()
        guard content != nil else { throw HostWorkerError.rejected }
        return Data()
    }

    func render() throws {
        guard let container, container.children.isEmpty, let presentation else { return }
        let result = try present(presentation)
        content = result
        let controller = result.controller
        container.addChild(controller)
        controller.view.frame = container.view.bounds
        controller.view.autoresizingMask = [.width, .height]
        container.view.addSubview(controller.view)
    }

    private func clearView() {
        if let presentation {
            try? content?.update(
                compact: presentation.compact, visible: false,
                width: presentation.availableWidth,
                intrinsic: !["main", "settings", "music.detail"].contains(
                    presentation.request.location))
        }
        for controller in container?.children ?? [] {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        content = nil
        presentation = nil
    }

    func release(reset: Bool = true) {
        generation = UUID()
        clearView()
        bootstrap.replace(nil)
        if let endpoint {
            endpoint.invalidate()
            let token = UUID()
            retiringEndpoints[token] = Task { [self] in
                await endpoint.invalidateAndWait()
                retiringEndpoints[token] = nil
            }
        }
        endpoint = nil
        request = nil
        session = nil
        if reset { try? resetEndpoint() }
    }
}

private final class HostRemoteSceneBootstrap: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoint: HostRemoteEndpoint?

    func replace(_ endpoint: HostRemoteEndpoint?) { lock.withLock { self.endpoint = endpoint } }
    func accept(_ connection: NSXPCConnection) -> Bool {
        lock.withLock { endpoint?.acceptBootstrap(connection) ?? false }
    }
}

@MainActor
private final class HostRemoteSceneController: NSViewController {
    let slot: HostRemoteSceneSlot

    init(slot: HostRemoteSceneSlot) { self.slot = slot; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        slot.container = self
        try? slot.render()
    }
}

private struct HostRemoteSceneView: NSViewControllerRepresentable {
    let slot: HostRemoteSceneSlot
    func makeNSViewController(context: Context) -> HostRemoteSceneController {
        HostRemoteSceneController(slot: slot)
    }
    func updateNSViewController(_ controller: HostRemoteSceneController, context: Context) {}
}

struct HostRemoteTerminalRenderer {
    private var sequences: [UUID: UInt64] = [:]

    mutating func release(_ presentationID: UUID) { sequences[presentationID] = nil }

    mutating func response(
        _ request: HostTerminalUIRequest, session: UUID, owner: String,
        configuredRequest: HostExtensionContentRequest?,
        execute: (String, NSDictionary) throws -> NSDictionary
    ) throws -> Data {
        guard let configuredRequest, configuredRequest.extensionID == owner else {
            throw HostWorkerError.rejected
        }
        try request.validate(
            session: session, request: configuredRequest, operation: request.operation.rawValue)
        let context = NSMutableDictionary(dictionary: [
            "presentationID": request.request.presentationID.uuidString
        ])
        if let event = request.event {
            guard event.sequence > (sequences[request.request.presentationID] ?? 0) else {
                throw HostWorkerError.rejected
            }
            sequences[request.request.presentationID] = event.sequence
            context["payload"] = try event.encoded(presentationID: request.request.presentationID)
        }
        let result = try execute(request.operation.rawValue, context)
        let data = try JSONSerialization.data(withJSONObject: result)
        guard !data.isEmpty, data.count <= 1024 else { throw HostWorkerError.invalidResponse }
        if request.operation == .status {
            _ = try HostTerminalUIStatus.decode(
                data, presentationID: request.request.presentationID)
        } else {
            struct Reply: Decodable { let ok: Bool }
            guard Set(result.allKeys.compactMap { $0 as? String }) == ["ok"] else {
                throw HostWorkerError.invalidResponse
            }
            _ = try JSONDecoder().decode(Reply.self, from: data)
        }
        return data
    }
}
