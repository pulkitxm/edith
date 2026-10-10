import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineWorkspacePaneTests {
    @Test(arguments: [InsertSide.left, .right, .top, .bottom])
    func splitUsesOriginalWorkspaceOperationAndSelectedTarget(_ side: InsertSide) throws {
        let layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        var store = WorkspaceStore(layouts: [layout], currentID: layout.id)
        let pane = try #require(layout.root.panes.first)
        let request = request(layout, action: .split, side: side)
        try request.apply(to: &store)
        let result = try #require(store.current)
        #expect(result.paneCount == 2)
        #expect(result.root.panes.allSatisfy { $0.tabs.first?.target == pane.tabs.first?.target })
        let split = try #require(result.root.split(result.root.id))
        #expect(split.axis == side.axis)
        #expect(split.children[side.isBefore ? 1 : 0].id == pane.id)
    }

    @Test(arguments: [InsertSide.left, .right, .top, .bottom])
    func resizeUsesNearestDirectionalDividerAndOriginalMinimum(_ side: InsertSide) throws {
        var layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        let original = try #require(layout.root.panes.first)
        layout.split(paneID: original.id, side: side, target: original.tabs[0].target)
        layout.focused = original.id
        var store = WorkspaceStore(layouts: [layout], currentID: layout.id)
        try request(layout, action: .resize, side: side, distance: 40, extent: 400).apply(
            to: &store)
        let split = try #require(store.current?.root.split(store.current!.root.id))
        #expect(abs(split.ratios[side.isBefore ? 1 : 0] - 0.55) < 0.000001)
        #expect(abs(split.ratios.reduce(0, +) - 1) < 0.000001)
        let current = try #require(store.current)
        #expect(throws: MachineUIError.self) {
            try request(current, action: .resize, side: side, distance: 4_096, extent: 400)
                .apply(to: &store)
        }
        #expect(store.current == current)
    }

    @Test func equalizeUsesOriginalExecutorAndRejectsWrongPaneTabAndBaseline() throws {
        var layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        let original = try #require(layout.root.panes.first)
        layout.split(paneID: original.id, side: .right, target: original.tabs[0].target)
        layout.focused = original.id
        layout.root.updateSplit(layout.root.id) { $0.ratios = [0.3, 0.7] }
        var store = WorkspaceStore(layouts: [layout], currentID: layout.id)
        try request(layout, action: .equalize).apply(to: &store)
        #expect(store.current?.root.split(layout.root.id)?.ratios == [0.5, 0.5])
        let before = store
        #expect(throws: MachineUIError.self) {
            try request(layout, action: .equalize).apply(to: &store)
        }
        let current = try #require(store.current)
        for invalid in [
            request(current, action: .equalize, paneID: UUID()),
            request(current, action: .equalize, tabID: UUID()),
            request(current, action: .equalize, side: .left),
            request(current, action: .resize, side: .left, distance: .infinity, extent: 400),
        ] {
            #expect(throws: MachineUIError.self) { try invalid.apply(to: &store) }
        }
        #expect(store.layouts == before.layouts)
    }

    @Test func resizeTraversesOppositeAxisWithoutChangingItsRatios() throws {
        var layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        let pane = layout.root.panes[0]
        layout.split(paneID: pane.id, side: .right, target: pane.tabs[0].target)
        layout.split(paneID: pane.id, side: .bottom, target: pane.tabs[0].target)
        layout.focused = pane.id
        var store = WorkspaceStore(layouts: [layout], currentID: layout.id)
        let root = try #require(layout.root.split(layout.root.id))
        let vertical = try #require(root.children.first?.split(root.children[0].id))
        try request(layout, action: .resize, side: .right, distance: 40, extent: 400)
            .apply(to: &store)
        #expect(store.current?.root.split(root.id)?.ratios == [0.55, 0.45])
        #expect(store.current?.root.split(vertical.id)?.ratios == vertical.ratios)
    }

    @Test func enginePersistsOnlyActivePresentationRejectsReplayReleaseAndDisable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        try WorkspaceStore.save(.init(layouts: [layout], currentID: layout.id), to: file)
        let id = UUID(), other = UUID()
        let (engine, terminals, owner) = try await engine(file, id: id)
        let first = request(
            layout, action: .split, side: .right, presentationID: id, terminal: owner)
        #expect(try await reply(engine, first).error != nil)
        await heartbeat(engine, id); await heartbeat(engine, other)
        #expect(try await reply(engine, first).error == nil)
        let saved = WorkspaceStore.load(from: file)
        #expect(saved.current?.paneCount == 2)
        #expect(try await reply(engine, first).error != nil)
        #expect(
            try await reply(
                engine, request(layout, action: .equalize, sequence: 2, terminal: owner)
            ).error != nil)
        _ = try await engine.execute(
            "machines.ui.release", payload: JSONEncoder().encode(MachineUIPresentation(id: id)))
        await heartbeat(engine, id)
        let current = try #require(saved.current)
        #expect(
            try await reply(
                engine,
                request(
                    current, action: .equalize, presentationID: id,
                    sequence: 2)
            ).error != nil)
        var otherOwner = MachineTerminalRequest(
            operation: .open, machineID: Machine.localID,
            workspaceTabID: current.root.pane(current.focused)!.selected, presentationID: other)
        otherOwner.handle = try await terminals.execute(otherOwner).handle
        otherOwner.operation = .read
        #expect(
            try await reply(
                engine,
                request(
                    current, action: .equalize,
                    presentationID: other, terminal: otherOwner)
            ).error == nil)
        let unchanged = try #require(WorkspaceStore.load(from: file).current)
        #expect(
            try await reply(
                engine,
                request(
                    unchanged, action: .equalize,
                    presentationID: other, terminal: otherOwner)
            ).error != nil)
        #expect(
            try await reply(
                engine,
                request(
                    unchanged, action: .equalize,
                    presentationID: other, sequence: 2, terminal: otherOwner)
            ).error == nil)
        await engine.shutdown()
        #expect(
            try await reply(
                engine,
                request(
                    current, action: .equalize,
                    presentationID: other, sequence: 2)
            ).error != nil)
        #expect(WorkspaceStore.load(from: file).current?.paneCount == 2)
        await terminals.shutdown()
    }

    @Test func exactRetainedTerminalRejectsForeignHandlePanePresentationAndClose() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        try WorkspaceStore.save(.init(layouts: [layout], currentID: layout.id), to: file)
        let id = UUID()
        let (engine, terminals, owner) = try await engine(file, id: id)
        let tabID = layout.root.pane(layout.focused)!.selected
        #expect(terminals.admitsPaneAction(owner, workspaceTabID: tabID))
        #expect(!terminals.admitsPaneAction(owner, workspaceTabID: UUID()))
        await heartbeat(engine, id)
        for field in 0..<4 {
            var forged = owner
            switch field {
            case 0: forged.handle = UUID()
            case 1: forged.tabID = UUID()
            case 2: forged.machineID = UUID()
            default: forged.presentationID = UUID()
            }
            #expect(!terminals.admitsPaneAction(forged, workspaceTabID: tabID))
            #expect(
                try await reply(
                    engine,
                    request(
                        layout, action: .split, side: .left,
                        presentationID: id, terminal: forged)
                ).error != nil)
        }
        #expect(WorkspaceStore.load(from: file).current == layout)
        var close = owner; close.operation = .close
        _ = try await terminals.execute(close)
        #expect(!terminals.admitsPaneAction(owner, workspaceTabID: tabID))
        #expect(
            try await reply(
                engine,
                request(
                    layout, action: .equalize,
                    presentationID: id, terminal: owner)
            ).error != nil)
        await engine.shutdown(); await terminals.shutdown()
    }

    @Test func cancelledInvocationDoesNotWriteTheOwnedStore() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let layout = WorkspaceLayout.single(machineID: Machine.localID, screen: .terminal)
        try WorkspaceStore.save(.init(layouts: [layout], currentID: layout.id), to: file)
        let id = UUID()
        let (engine, terminals, owner) = try await engine(file, id: id)
        await heartbeat(engine, id)
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return try await reply(
                engine,
                request(
                    layout, action: .split, side: .right,
                    presentationID: id, terminal: owner))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(WorkspaceStore.load(from: file).current == layout)
        await engine.shutdown(); await terminals.shutdown()
    }

    private func request(
        _ layout: WorkspaceLayout, action: MachineWorkspacePaneRequest.Action,
        side: InsertSide? = nil, distance: Double? = nil, extent: Double? = nil,
        paneID: UUID? = nil, tabID: UUID? = nil, presentationID: UUID = UUID(),
        sequence: UInt64 = 1, terminal: MachineTerminalRequest? = nil
    ) -> MachineWorkspacePaneRequest {
        let pane = layout.root.pane(layout.focused)!
        return MachineWorkspacePaneRequest(
            presentationID: presentationID,
            terminal: terminal
                ?? MachineTerminalRequest(operation: .read, machineID: Machine.localID),
            sequence: sequence, baseline: layout,
            paneID: paneID ?? pane.id, tabID: tabID ?? pane.selected, action: action,
            side: side, distance: distance, extent: extent)
    }

    private func engine(_ file: URL, id: UUID) async throws
        -> (MachineUIEngine, MachineTerminalEngine, MachineTerminalRequest)
    {
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let terminals = MachineTerminalEngine(
            session: { _ in session },
            launch: { _, _ in
                MachinePTYLaunch(
                    executable: "/bin/sh", arguments: ["-c", "IFS= read -r value"],
                    environment: ["PATH=/usr/bin:/bin"], currentDirectory: "/private/tmp",
                    startupCommand: nil)
            })
        let layout = WorkspaceStore.load(from: file).current!
        var owner = MachineTerminalRequest(
            operation: .open, machineID: Machine.localID,
            workspaceTabID: layout.root.pane(layout.focused)!.selected, presentationID: id)
        owner.handle = try await terminals.execute(owner).handle
        owner.operation = .read
        let engine = MachineUIEngine(
            session: { _ in throw MachineUIError.invalidRequest },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [],
                    workspaces: WorkspaceStore.load(from: file))
            },
            mutation: { _ in throw MachineUIError.invalidRequest },
            workspace: { try WorkspaceStore.save($0, to: file) },
            paneAdmission: { terminals.admitsPaneAction($0, workspaceTabID: $1) },
            presentationRelease: { terminals.release($0) })
        return (engine, terminals, owner)
    }

    private func heartbeat(_ engine: MachineUIEngine, _ id: UUID) async {
        _ = try? await engine.execute(
            "machines.ui.heartbeat",
            payload: JSONEncoder().encode(MachineUIPresentation(id: id)))
    }

    private func reply(_ engine: MachineUIEngine, _ request: MachineWorkspacePaneRequest)
        async throws -> MachineUIReply
    {
        try JSONDecoder().decode(
            MachineUIReply.self,
            from: await engine.execute(
                "machines.ui.workspace.pane", payload: JSONEncoder().encode(request)))
    }
}
