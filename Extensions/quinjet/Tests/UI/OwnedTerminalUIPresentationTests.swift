import Foundation
import GhosttyTerminal
import Testing

@testable import QuinjetUI

@MainActor @Suite(.serialized) struct OwnedTerminalUIPresentationTests {
    @Test func sealedHostEventsRejectStaleWrongReplacedAndClosedPresentations() throws {
        let id = UUID()
        var closed = 0
        var actions = 0
        let binding = OwnedTerminalUIPresentation(
            id: id, holders: { [] },
            action: { _ in
                actions += 1; return true
            }, paneAction: { _, _ in }, close: { closed += 1 })
        func send(
            _ sequence: UInt64, token: UUID? = nil, action: OwnedTerminalUIEvent.Action? = nil
        ) throws -> Bool {
            let event = OwnedTerminalUIEvent(
                version: 1, presentationID: token ?? id, sequence: sequence,
                active: true, key: true, visible: true, action: action)
            return binding.execute([
                "operation": "terminalUI", "presentationID": id.uuidString,
                "payload": try JSONEncoder().encode(event),
            ])["ok"] as? Bool == true
        }
        #expect(try send(1))
        #expect(try !send(1))
        #expect(try !send(2, token: UUID()))
        #expect(try !send(2, action: .fontZoomIn))
        #expect(actions == 0)
        #expect(
            binding.execute(["operation": "terminalUIStatus", "presentationID": id.uuidString])[
                "focused"] as? Bool == false)
        #expect(
            binding.execute(["operation": "terminalUIStatus", "presentationID": UUID().uuidString])[
                "ok"] as? Bool == false)
        #expect(try send(3, action: .windowClosed))
        #expect(closed == 1 && actions == 0)
        #expect(try !send(4))
        #expect(
            binding.execute(["operation": "terminalUIStatus", "presentationID": id.uuidString])[
                "ok"] as? Bool == false)
    }

}
