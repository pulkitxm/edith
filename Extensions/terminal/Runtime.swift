import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import GhosttyTerminal
import SwiftUI

@MainActor
final class TerminalService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var engine: TerminalEngine?
    private var surface: TerminalSurface?
    private struct Presentation {
        let model: TerminalTabsModel
        var controller: NSViewController?
        var events: TerminalUIEventTracker
    }
    private var presentations: [UUID: Presentation] = [:]
    private var uiStops: [UUID: Task<Void, Never>] = [:]
    private let makeEngine: @MainActor () -> TerminalEngine

    init(runtime: ExtensionServiceRuntime, makeEngine: @escaping @MainActor () -> TerminalEngine) {
        self.runtime = runtime
        self.makeEngine = makeEngine
    }

    private var admissionClosed: Bool { runtime.isSuspended || runtime.isStopping }

    var isRunning: Bool { engine?.isStopped == false }

    var allowsUIDuringRetirement: Bool { true }

    func acceptsStopUI(for presentation: UUID?) -> Bool {
        presentation.map { presentations[$0] != nil } ?? true
    }

    func start() -> Bool {
        guard !ExtensionHostRole.isInterfaceProcess else { return false }
        if engine == nil {
            let engine = makeEngine()
            self.engine = engine
            surface = TerminalSurface(engine: engine)
        }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let engine else { throw ExtensionPeerError.unavailable }
        if command.hasPrefix("surface.") {
            guard let surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
        return try await engine.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !configuration.uiOnly, let client = configuration.engineClient else { return false }
        let id = client.presentationID
        guard uiStops.count < 16, presentations[id] != nil || presentations.count < 16 else {
            client.invalidate()
            return false
        }
        if let previous = presentations.removeValue(forKey: id) { retire(previous) }
        presentations[id] = Presentation(
            model: TerminalTabsModel(client: TerminalRemoteClient(client: client)),
            events: TerminalUIEventTracker(presentationID: id))
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard !admissionClosed, var current = presentations[presentation] else { return nil }
        if let controller = current.controller { return controller }
        let model = current.model
        let controller = NSHostingController(
            rootView: ExtensionPageHost {
                TerminalPage(model: model, onWindowClose: { model.windowClosed() })
            })
        current.controller = controller
        presentations[presentation] = current
        return controller
    }

    func synchronize() {
        for presentation in presentations.values { presentation.model.synchronize() }
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !admissionClosed else { return false }
        synchronize()
        return true
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        switch operation {
        case "terminalUI":
            guard !admissionClosed, let data = context["payload"] as? Data,
                let value = context["presentationID"] as? String, let id = UUID(uuidString: value),
                var presentation = presentations[id],
                let event = try? presentation.events.accept(data)
            else { return nil }
            presentations[id] = presentation
            return ["ok": presentation.model.applyUIEvent(event)] as NSDictionary
        case "terminalUIStatus":
            guard let value = context["presentationID"] as? String,
                let id = UUID(uuidString: value),
                let presentation = presentations[id]
            else { return nil }
            return [
                "ok": true,
                "focused": presentation.model.selectedTab?.holder.ghosttyView?.hasInputFocus
                    == true,
                "presentationID": id.uuidString,
            ] as NSDictionary
        default: return nil
        }
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        stopPresentations(presentation)
    }

    func cancelPendingWork() {
        _ = stopPresentations(nil)
        engine?.beginSuspension()
    }

    func drain() async {
        do { try await engine?.stopAndWait() } catch { return }
        await awaitUIStops()
    }

    func teardown() async {
        _ = stopPresentations(nil)
        await awaitUIStops()
        engine?.stop()
        engine = nil
        surface = nil
    }

    private func awaitUIStops() async {
        for task in Array(uiStops.values) { await task.value }
    }

    private func stopPresentations(_ id: UUID?) -> [Task<Void, Never>] {
        guard !presentations.isEmpty else { return [] }
        var tasks: [Task<Void, Never>] = []
        for identifier in id.map({ [$0] }) ?? Array(presentations.keys) {
            if let presentation = presentations.removeValue(forKey: identifier) {
                tasks.append(retire(presentation))
            }
        }
        finishUIStop()
        return tasks
    }

    @discardableResult
    private func retire(_ presentation: Presentation) -> Task<Void, Never> {
        let id = UUID()
        presentation.model.stopAll()
        let task = Task { [self, presentation] in
            await presentation.model.stopAllAndWait()
            uiStops[id] = nil
            finishUIStop()
        }
        uiStops[id] = task
        return task
    }

    private func finishUIStop() {
        guard presentations.isEmpty, uiStops.isEmpty else { return }
        ExtensionUIResources.cleanup(of: runtime, key: "ghostty") {
            GhosttyRuntime.shared.shutdown()
        }
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
    }
}

@MainActor
func makeTerminalRuntime(
    makeEngine: @escaping @MainActor () -> TerminalEngine = { TerminalEngine() }
) -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "terminal", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { TerminalService(runtime: $0, makeEngine: makeEngine) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeTerminalRuntime()).toOpaque())
        })
}
