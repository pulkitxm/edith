import Foundation
import GhosttyTerminal
import Testing

@testable import HerdrUI

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

    @Test func originalSpacePaneActionsPreserveSplitFocusZoomResizeAndTabsWithoutLaunching() throws
    {
        let store = HerdrStore(defaults: HerdrUIDefaults(), machinesProvider: { [] })
        let model = HerdrSpaceWindowModel(
            space: .init(id: "synthetic", title: "Synthetic", agents: []), store: store)
        defer { model.stopAll(); HerdrWorkOwnership.enable() }
        let first = try #require(model.selectedTab)
        let holder = try #require(first.holders.first)
        model.terminalPaneAction(.split(.right), holder: holder)
        #expect(first.layout.paneCount == 2)
        let selected = first.layout.focused
        model.terminalPaneAction(.focus(.previous), holder: holder)
        #expect(first.layout.focused != selected)
        model.terminalPaneAction(.focus(.right), holder: holder)
        #expect(first.layout.focused == selected)
        model.terminalPaneAction(.toggleZoom, holder: holder)
        #expect(first.layout.maximized == selected)
        model.terminalPaneAction(.toggleZoom, holder: holder)
        #expect(first.layout.maximized == nil)
        let before = first.layout.root
        model.terminalPaneAction(.resize(.left, 3), holder: holder)
        #expect(first.layout.root != before)
        model.terminalPaneAction(.equalize, holder: holder)
        #expect(first.layout.root == before)
        model.terminalPaneAction(.newTab, holder: holder)
        #expect(model.tabs.count == 2 && model.selected != first.id)
        let next = try #require(model.selectedTab?.holders.first)
        model.terminalPaneAction(.selectTab(1), holder: next)
        #expect(model.selected == first.id)
        #expect(model.tabs.flatMap(\.holders).allSatisfy { !$0.started && $0.descriptor == nil })
    }
}
