import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct WindowSessionOwnerTests {
    @Test func sessionsStayWithinTheirWindowOwner() {
        let first = WindowSessionOwner()
        let second = WindowSessionOwner()
        let quinjet = first.quinjet
        let capture = first.capture
        quinjet.addPickerTab()
        capture.note = "synthetic draft"

        #expect(first.quinjet === quinjet)
        #expect(first.capture === capture)
        #expect(second.quinjet !== quinjet)
        #expect(second.capture !== capture)
        #expect(second.quinjet.tabs.count == 1)
        #expect(second.capture.note.isEmpty)
        second.capture.setCaptureActive(false)
        #expect(first.capture.note == "synthetic draft")
    }

    @Test func bridgeTargetsFocusedHostAndPreservesSurvivingAttachments() {
        let bridge = QuinjetSessionBridge()
        let first = WindowSessionOwner()
        let second = WindowSessionOwner()
        let firstRouter = WindowRouter()
        let secondRouter = WindowRouter()
        let firstToken = UUID()
        let secondToken = UUID()
        bridge.attach(first.quinjet, token: firstToken, router: firstRouter)
        bridge.attach(second.quinjet, token: secondToken, router: secondRouter)

        #expect(bridge.model(for: firstRouter) === first.quinjet)
        #expect(bridge.model(for: secondRouter) === second.quinjet)
        #expect(bridge.model(for: nil) === second.quinjet)
        bridge.detach(token: firstToken)
        #expect(bridge.model(for: nil) === second.quinjet)
        bridge.attach(first.quinjet, token: firstToken, router: firstRouter)
        bridge.detach(token: firstToken)
        #expect(bridge.model(for: secondRouter) === second.quinjet)
        bridge.detach(token: secondToken)
        #expect(bridge.model(for: nil) == nil)
    }
}
