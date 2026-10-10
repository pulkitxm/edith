import EdithExtensionSupport
import Foundation
import GhosttyTerminal
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineNativePaneActionTests {
    @Test func scopedFacadeChangesTheActualEngineStoreAndDisableCancelsQueuedWork() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        try WorkspaceStore.save(.init(layouts: [layout], currentID: layout.id), to: file)
        let bridge = MachinePaneEngineBridge(file: file)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let facade = MachineUIClient(client: client)
        let machines = MachinesModel(uiClient: facade)
        let model = WorkspaceModel(machines: machines)
        model.applyUIState(WorkspaceStore.load(from: file))
        _ = try await bridge.engine.execute(
            "machines.ui.heartbeat",
            payload: JSONEncoder().encode(MachineUIPresentation(id: client.presentationID)))
        let pane = try #require(layout.root.panes.first)
        var owner = MachineTerminalRequest(
            operation: .open, machineID: Machine.localID,
            workspaceTabID: pane.selected, presentationID: client.presentationID)
        owner.handle = try await bridge.terminals.execute(owner).handle
        owner.operation = .read
        model.performNativePaneAction(
            .split(.right), paneID: pane.id, tabID: pane.selected,
            size: .init(width: 400, height: 300), cellExtent: 8, terminal: owner,
            isCurrent: { true })
        await model.awaitPaneActions()
        #expect(WorkspaceStore.load(from: file).current?.paneCount == 2)
        #expect(model.layout.paneCount == 2)
        let livePane = try #require(model.layout.root.pane(model.layout.focused))
        var liveOwner = MachineTerminalRequest(
            operation: .open, machineID: Machine.localID,
            workspaceTabID: livePane.selected, presentationID: client.presentationID)
        liveOwner.handle = try await bridge.terminals.execute(liveOwner).handle
        liveOwner.operation = .read
        model.performNativePaneAction(
            .resize(.left, 5), paneID: livePane.id,
            tabID: livePane.selected, size: .init(width: 400, height: 300), cellExtent: 8,
            terminal: liveOwner, isCurrent: { true })
        await model.awaitPaneActions()
        #expect(
            WorkspaceStore.load(from: file).current?.root.split(model.layout.root.id)?.ratios
                == [0.45, 0.55])
        model.performNativePaneAction(
            .equalize, paneID: livePane.id,
            tabID: livePane.selected, size: .zero, cellExtent: 0, terminal: liveOwner,
            isCurrent: { true })
        await model.awaitPaneActions()
        #expect(
            WorkspaceStore.load(from: file).current?.root.split(model.layout.root.id)?.ratios
                == [0.5, 0.5])
        let before = model.layout
        model.performNativePaneAction(
            .equalize, paneID: UUID(), tabID: pane.selected,
            size: .zero, cellExtent: 0, terminal: owner, isCurrent: { true })
        await model.awaitPaneActions()
        #expect(model.operationError != nil)
        #expect(model.layout == before)
        let count = bridge.requests
        model.performNativePaneAction(
            .equalize, paneID: pane.id, tabID: pane.selected,
            size: .zero, cellExtent: 0, terminal: owner, isCurrent: { false })
        await model.awaitPaneActions()
        #expect(bridge.requests == count)
        model.performNativePaneAction(
            .split(.down), paneID: livePane.id, tabID: livePane.selected,
            size: .zero, cellExtent: 0, terminal: liveOwner, isCurrent: { true })
        await model.shutdown()
        #expect(bridge.requests == count)
        #expect(WorkspaceStore.load(from: file).current == before)
        facade.shutdown(); await bridge.engine.shutdown(); await bridge.terminals.shutdown()
    }

    @Test func disabledFacadeRejectsLateActualEngineReplyAndCancelsItsExactToken() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        try WorkspaceStore.save(.init(layouts: [layout], currentID: layout.id), to: file)
        let bridge = MachinePaneEngineBridge(file: file)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let facade = MachineUIClient(client: client)
        let model = WorkspaceModel(machines: MachinesModel(uiClient: facade))
        model.applyUIState(WorkspaceStore.load(from: file))
        _ = try await bridge.engine.execute(
            "machines.ui.heartbeat",
            payload: JSONEncoder().encode(MachineUIPresentation(id: client.presentationID)))
        let pane = try #require(layout.root.panes.first)
        var owner = MachineTerminalRequest(
            operation: .open, machineID: Machine.localID,
            workspaceTabID: pane.selected, presentationID: client.presentationID)
        owner.handle = try await bridge.terminals.execute(owner).handle
        owner.operation = .read
        bridge.holdReply = true
        model.performNativePaneAction(
            .split(.down), paneID: pane.id, tabID: pane.selected,
            size: .zero, cellExtent: 0, terminal: owner, isCurrent: { true })
        for _ in 0..<500 {
            if bridge.hasHeldReply { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(bridge.hasHeldReply)
        #expect(WorkspaceStore.load(from: file).current?.paneCount == 2)
        model.stopPaneActions(); facade.shutdown()
        bridge.completeHeldReply()
        await model.awaitPaneActions()
        #expect(model.layout == layout)
        #expect(Set(bridge.cancelled) == Set(bridge.tokens))
        #expect(Set(bridge.cancelled).count == 1)
        await model.shutdown(); await bridge.engine.shutdown(); await bridge.terminals.shutdown()
    }

    @Test func nativeCallbackRequiresActualFocusedRegisteredRendererAndCurrentGeneration() throws {
        let bridge = MachinePaneRejectingBridge()
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let facade = MachineUIClient(client: client)
        let session = MachineSession(
            machine: .local, local: true, synthetic: true, uiClient: facade)
        let holder = TerminalSessionHolder()
        holder.start(session: session)
        holder.presented = true
        var calls = 0
        holder.hostPaneAction = { _, _, _, _ in calls += 1 }
        let view = holder.retainedGhosttyView(
            theme: GhosttyTheme(background: "#000000", foreground: "#ffffff", cursor: "#ffffff"))
        #expect(view.onPaneAction != nil)
        #expect(
            try facade.terminalUI.accept(
                JSONEncoder().encode(
                    MachineTerminalUIEvent(
                        version: 1, presentationID: client.presentationID, sequence: 1,
                        active: true, key: true, visible: true, action: nil))))
        #expect(!view.hasInputFocus)
        #expect(!facade.terminalUI.admitsPaneAction(holder))
        view.onPaneAction?(.split(.right)); view.onPaneAction?(.resize(.left, 10))
        view.onPaneAction?(.equalize)
        #expect(calls == 0)
        let callback = view.onPaneAction
        holder.reset()
        callback?(.split(.down))
        #expect(calls == 0)
        #expect(holder.hostPaneAction == nil)
        facade.shutdown()
        callback?(.equalize)
        #expect(calls == 0)
    }
}

@MainActor private final class MachinePaneEngineBridge: NSObject {
    let engine: MachineUIEngine
    let terminals: MachineTerminalEngine
    var tokens: [String] = []
    var requests = 0
    var holdReply = false
    var cancelled: [String] = []
    private var heldReply: (@Sendable (NSData) -> Void, NSData)?
    var hasHeldReply: Bool { heldReply != nil }
    func completeHeldReply() {
        guard let heldReply else { return }
        self.heldReply = nil
        heldReply.0(heldReply.1)
    }
    init(file: URL) {
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let terminals = MachineTerminalEngine(
            session: { _ in session },
            launch: { _, _ in
                MachinePTYLaunch(
                    executable: "/bin/sh", arguments: ["-c", "IFS= read -r value"],
                    environment: ["PATH=/usr/bin:/bin"], currentDirectory: "/private/tmp",
                    startupCommand: nil)
            })
        self.terminals = terminals
        engine = MachineUIEngine(
            session: { _ in throw MachineUIError.invalidRequest },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [],
                    workspaces: WorkspaceStore.load(from: file))
            },
            mutation: { _ in throw MachineUIError.invalidRequest },
            workspace: { try WorkspaceStore.save($0, to: file) },
            paneAdmission: { terminals.admitsPaneAction($0, workspaceTabID: $1) })
    }
    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        Task { @MainActor in
            do {
                let request = try ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self,
                    from: data as Data)
                requests += 1; tokens.append(request.token.uuidString)
                let payload = try await engine.execute(request.operation, payload: request.payload)
                let reply =
                    try ExtensionEngineWire.encode(
                        ExtensionEngineReply(
                            token: request.token, ok: true, payload: payload)) as NSData
                if holdReply { heldReply = (completion, reply) } else { completion(reply) }
            } catch { Issue.record(error) }
        }
    }
    @objc func cancel(_ token: NSString) { cancelled.append(token as String) }
}

@MainActor private final class MachinePaneRejectingBridge: NSObject {
    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        Issue.record("A renderer without actual focus invoked the engine")
    }
    @objc func cancel(_ token: NSString) {}
}
