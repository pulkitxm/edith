@testable import HerdrUI
import EdithExtensionSupport
import AppKit
import Foundation
import Testing

@MainActor
@Suite struct HerdrPageKeysTests {
    private func store() -> HerdrStore {
        let suite = "HerdrPageKeysTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return HerdrStore(defaults: defaults)
    }

    private func agent(_ kind: String, pane: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: pane, kind: kind, status: .idle, title: kind,
            workspace: "", cwd: "")
    }

    private func page(_ store: HerdrStore, identifier: String) -> NSWindow {
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        store.movePage(from: nil, to: window)
        return window
    }

    @Test func commandKOpensSearchOnlyInPageWindows() {
        let store = store()
        let main = page(store, identifier: "EdithMainWindow")
        let other = NSWindow()
        #expect(
            !store.performPageKey(
                characters: "k", keyCode: 40, modifiers: .command, repeats: false, in: other))
        #expect(!store.searchPresented)
        #expect(
            store.performPageKey(
                characters: "k", keyCode: 40, modifiers: .command, repeats: false, in: main))
        #expect(store.searchPresented)
    }

    @Test func detailChordTogglesDetailsForAnOpenAgent() {
        let store = store()
        let main = page(store, identifier: "EdithMainWindow")
        let before = store.detailOpen
        #expect(
            !store.performPageKey(
                characters: "b", keyCode: 11, modifiers: [.command, .option], repeats: false,
                in: main))
        #expect(store.detailOpen == before)
        store.open(agent("Claude Code", pane: "a"))
        #expect(
            store.performPageKey(
                characters: "b", keyCode: 11, modifiers: [.command, .option], repeats: false,
                in: main))
        #expect(store.detailOpen != before)
        #expect(
            store.performPageKey(
                characters: "b", keyCode: 11, modifiers: [.command, .option], repeats: true,
                in: main))
        #expect(store.detailOpen != before)
    }

    @Test func controlTabCyclesTabsAndCommandWClosesTheFocusedTab() {
        let store = store()
        let main = page(store, identifier: "EdithMainWindow")
        store.open(agent("Claude Code", pane: "a"))
        store.selectBoard()
        #expect(
            store.performPageKey(
                characters: "\t", keyCode: 48, modifiers: .control, repeats: false, in: main))
        #expect(store.selectedTab != HerdrStore.boardID)
        #expect(
            store.performPageKey(
                characters: "w", keyCode: 13, modifiers: .command, repeats: false, in: main))
        #expect(store.tabs.isEmpty)
    }

    @Test func commandWIsLeftToDetachedWindows() {
        let store = store()
        let section = page(store, identifier: "EdithSection.herdr")
        store.open(agent("Claude Code", pane: "a"))
        #expect(
            !store.performPageKey(
                characters: "w", keyCode: 13, modifiers: .command, repeats: false, in: section))
        #expect(store.tabs.count == 1)
    }

    @Test func sceneDetailChordFollowsTheSurface() {
        let store = store()
        let window = page(store, identifier: "EdithSection.x")
        let before = store.detailOpen
        #expect(
            !store.performSceneKey(
                characters: "b", modifiers: [.command, .option], repeats: false, in: window,
                surface: .space(hasAgent: false)))
        #expect(
            store.performSceneKey(
                characters: "b", modifiers: [.command, .option], repeats: false, in: window,
                surface: .agentWindow))
        #expect(store.detailOpen != before)
    }
}
