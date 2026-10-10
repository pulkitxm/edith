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
    private var stopping = false

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
        guard !stopping else { throw HostWorkerError.exited }
        switch command.operation {
        case "configure":
            guard configuration == nil else { throw HostWorkerError.rejected }
            let next = try HostRemoteWire.decode(
                HostRemoteConfiguration.self, from: command.payload)
            try next.validate(
                hostIdentifier: hostIdentifier, extensionID: extensionID, version: version)
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
            for runtime in runtimes {
                _ = try runtime.response(
                    id: extensionID, operation: "releaseUI",
                    context: ["presentationID": id.uuidString])
            }
            return Data()
        case "stop":
            shutdown()
            return Data()
        default: throw HostWorkerError.rejected
        }
    }

    private func controller(
        presentation: HostRemotePresentation
    ) throws -> ExtensionBundlePresentation {
        guard let configuration, !stopping else { throw HostWorkerError.rejected }
        try presentation.validate(session: configuration.session, extensionID: extensionID)
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
        throw HostWorkerError.rejected
    }

    private func terminal(_ request: HostTerminalUIRequest) throws -> Data {
        guard !stopping, let configuration, !configuration.uiOnly, extensionID == "terminal",
            let runtime = presentationRuntimes[request.request.presentationID]
        else { throw HostWorkerError.rejected }
        try request.validate(
            session: configuration.session, request: request.request,
            operation: request.operation.rawValue)
        let context = NSMutableDictionary(dictionary: [
            "presentationID": request.request.presentationID.uuidString
        ])
        if let event = request.event {
            context["payload"] = try event.encoded(presentationID: request.request.presentationID)
        }
        let result = try runtime.response(
            id: extensionID, operation: request.operation.rawValue, context: context)
        let data = try JSONSerialization.data(withJSONObject: result)
        guard data.count <= 1024 else { throw HostWorkerError.invalidResponse }
        if request.operation == .status {
            _ = try HostTerminalUIStatus.decode(
                data, presentationID: request.request.presentationID)
        }
        return data
    }

    private func shutdown() {
        guard !stopping else { return }
        stopping = true
        slots.forEach { $0.release() }
        presentationRuntimes.removeAll()
        for runtime in runtimes { _ = try? runtime.response(id: extensionID, operation: "stopUI") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            endpoint.invalidate()
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

    func beginClosing() { closing = true }

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

    func release() {
        generation = UUID()
        clearView()
        bootstrap.replace(nil)
        endpoint?.invalidate()
        endpoint = nil
        request = nil
        session = nil
        try? resetEndpoint()
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
