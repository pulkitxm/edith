import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineTerminalUIEventTests {
    @Test func eventsBindExactPresentationSequenceVersionAndByteLimit() throws {
        let id = UUID()
        let scope = MachineTerminalUIPresentation(presentationID: id)
        #expect(!scope.focused)
        #expect(try scope.accept(data(id: id, sequence: 4)))
        #expect(throws: MachineUIError.self) { try scope.accept(data(id: id, sequence: 4)) }
        #expect(throws: MachineUIError.self) { try scope.accept(data(id: id, sequence: 3)) }
        #expect(throws: MachineUIError.self) { try scope.accept(data(id: UUID(), sequence: 5)) }
        #expect(throws: MachineUIError.self) {
            try scope.accept(data(id: id, sequence: 5, version: 2))
        }
        #expect(throws: MachineUIError.self) { try scope.accept(Data(repeating: 0, count: 1_025)) }
        #expect(try scope.accept(data(id: id, sequence: 5)))
        #expect(!scope.focused)
        #expect(!scope.acceptedActionWithoutFocus(id: id, sequence: 6))
        scope.invalidate()
        #expect(throws: MachineUIError.self) { try scope.accept(data(id: id, sequence: 7)) }
    }

    @Test func windowCloseStopsOnlyItsConfiguredPresentationAndRejectsLateRestart() throws {
        let bridge = TerminalUIFixtureBridge()
        let first = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let second = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let firstClient = MachineUIClient(client: first)
        let secondClient = MachineUIClient(client: second)
        let one = MachineSession(
            machine: .local, local: true, synthetic: true, uiClient: firstClient)
        let two = MachineSession(
            machine: .local, local: true, synthetic: true, uiClient: secondClient)
        let firstHolder = TerminalSessionHolder()
        let secondHolder = TerminalSessionHolder()
        firstHolder.start(session: one); secondHolder.start(session: two)
        #expect(firstHolder.started && secondHolder.started)
        #expect(
            try firstClient.terminalUI.accept(
                data(id: first.presentationID, sequence: 1, action: .windowClosed)))
        #expect(!firstHolder.started)
        #expect(secondHolder.started)
        firstHolder.start(session: one)
        #expect(!firstHolder.started)
        #expect(!firstClient.terminalUI.focused)
        secondClient.shutdown()
        #expect(!secondHolder.started)
        firstClient.shutdown()
    }

    @Test func hostTabActionsUseOriginalModelsAndExactWorkspacePane() async throws {
        let tabs = TerminalTabsModel(requestUserClose: { holder, complete in
            holder.stop(); complete(true)
        })
        #expect(tabs.performHostTabAction(.newTab))
        #expect(tabs.tabs.count == 1)
        let first = tabs.selected
        #expect(tabs.performHostTabAction(.newTab))
        #expect(tabs.performHostTabAction(.previousTab))
        #expect(tabs.selected == first)
        #expect(tabs.performHostTabAction(.nextTab))
        #expect(tabs.selected != first)
        #expect(tabs.performHostTabAction(.closeTab))
        #expect(tabs.tabs.count == 1)
        #expect(!tabs.performHostTabAction(.fontZoomIn))
        tabs.stopAll()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = WorkspaceModel(machines: .shared, file: file)
        await model.awaitInitialLoad()
        let pane = try #require(model.layout.root.panes.first)
        let target = PaneTarget(machineID: UUID(), screen: .terminal)
        #expect(model.performHostTabAction(.newTab, paneID: pane.id, target: target))
        #expect(model.layout.root.pane(pane.id)?.tabs.count == 2)
        #expect(model.performHostTabAction(.previousTab, paneID: pane.id, target: target))
        #expect(model.layout.focused == pane.id)
        #expect(model.performHostTabAction(.closeTab, paneID: pane.id, target: target))
        #expect(model.layout.root.pane(pane.id)?.tabs.count == 1)
        let before = model.layout
        #expect(!model.performHostTabAction(.newTab, paneID: UUID(), target: target))
        #expect(
            !model.performHostTabAction(
                .newTab, paneID: pane.id, target: .init(machineID: UUID(), screen: .files)))
        #expect(model.layout == before)
        await model.shutdown()
    }

    private func data(
        id: UUID, sequence: UInt64, version: Int = 1,
        action: MachineTerminalUIEvent.Action? = nil
    ) throws -> Data {
        try JSONEncoder().encode(
            MachineTerminalUIEvent(
                version: version, presentationID: id,
                sequence: sequence, active: true, key: true, visible: true, action: action))
    }
}

extension MachineTerminalUIPresentation {
    fileprivate func acceptedActionWithoutFocus(id: UUID, sequence: UInt64) -> Bool {
        (try? accept(
            JSONEncoder().encode(
                MachineTerminalUIEvent(
                    version: 1, presentationID: id,
                    sequence: sequence, active: true, key: true, visible: true, action: .newTab))))
            ?? false
    }
}

@MainActor private final class TerminalUIFixtureBridge: NSObject {
    @objc func invoke(_ data: NSData, completion: @escaping (NSData) -> Void) {
        Issue.record("Unexpected engine work")
    }
    @objc func cancel(_ token: NSString) {}
    @objc func invalidate() {}
}
