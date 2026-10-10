import EdithExtensionSupport
import Foundation
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalUIEventTests {
    private func data(id: UUID, sequence: UInt64, action: TerminalUIEvent.Action? = nil) throws
        -> Data
    {
        try JSONEncoder().encode(
            TerminalUIEvent(
                version: 1, presentationID: id, sequence: sequence, active: false, key: false,
                visible: false, action: action))
    }

    @Test func eventsRejectOtherPresentationsStaleSequencesAndOversizedMessages() throws {
        let id = UUID()
        var tracker = TerminalUIEventTracker(presentationID: id)
        #expect(try tracker.accept(data(id: id, sequence: 3)).sequence == 3)
        #expect(throws: ExtensionPeerError.self) {
            try tracker.accept(data(id: UUID(), sequence: 4))
        }
        #expect(throws: ExtensionPeerError.self) { try tracker.accept(data(id: id, sequence: 3)) }
        #expect(throws: ExtensionPeerError.self) { try tracker.accept(data(id: id, sequence: 2)) }
        #expect(throws: ExtensionPeerError.self) {
            try tracker.accept(Data(repeating: 0, count: 1_025))
        }
        #expect(try tracker.accept(data(id: id, sequence: 4)).sequence == 4)
    }

    @Test func inactiveHostEventsCannotLaunchSessionsAndWindowCloseStopsOwnedPTYs() async throws {
        let engine = TerminalTestFixture.engine()
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        let model = TerminalTabsModel(client: remote)
        defer { model.stopAll() }
        await remote.open(); model.synchronize()
        let event = try JSONDecoder().decode(
            TerminalUIEvent.self, from: data(id: UUID(), sequence: 1, action: .newTab))
        #expect(!model.applyUIEvent(event))
        #expect(try engine.snapshot().sessions.count == 1)
        let close = try JSONDecoder().decode(
            TerminalUIEvent.self,
            from: data(id: event.presentationID, sequence: 2, action: .windowClosed))
        #expect(model.applyUIEvent(close))
        try await TerminalTestFixture.wait { model.tabs.isEmpty }
        #expect(try engine.snapshot().sessions.isEmpty)
    }
}
