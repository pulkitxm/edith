import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct HerdrTabLayoutTests {
    @Test func openingBesideBuildsOneSideBySideTab() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        store.open(codex, beside: .right)

        let tab = try #require(store.currentTab)
        #expect(store.tabs.count == 1)
        #expect(tab.agentIDs == [claude.id, codex.id])
        #expect(tab.focused == codex.id)
        #expect(store.focusedSession?.id == codex.id)
    }

    @Test func openingBesideMovesAnAgentOutOfItsOwnTab() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        let first = try #require(store.currentTab).id
        store.open(codex)
        store.selectedTab = first

        store.open(codex, beside: .bottom)

        #expect(store.tabs.map(\.id) == [first])
        #expect(store.sessions.count == 2)
        let frames = try #require(store.currentTab).layout.frames(
            in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(frames[codex.id] == CGRect(x: 0, y: 50, width: 100, height: 50))
    }

    @Test func splitViewIsOfferedOnlyWhileAnAgentIsAlone() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude, showing: .split)
        #expect(store.shownView(for: claude.id) == .split)
        #expect(store.views(for: claude.id) == [.agent, .split, .diff])

        store.open(codex, beside: .right)
        #expect(store.shownView(for: claude.id) == .agent)
        #expect(store.views(for: claude.id) == [.agent, .diff])
        store.setView(.split, for: codex.id)
        #expect(store.view(for: codex.id) == .agent)
        #expect(store.view(for: claude.id) == .split)

        store.moveToNewTab(codex.id)
        #expect(store.tabs.count == 2)
        #expect(store.shownView(for: claude.id) == .split)
    }

    @Test func diffStaysAvailableInsideASharedTab() {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        store.open(claude)
        store.open(agent("Codex", pane: "b"), beside: .right)
        store.setView(.diff, for: claude.id)
        #expect(store.shownView(for: claude.id) == .diff)
    }

    @Test func closingOnePaneKeepsTheRestOfTheTab() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let agents = ["a", "b", "c"].map { agent("Codex", pane: $0) }
        store.open(agents[0])
        store.open(agents[1], beside: .right)
        store.open(agents[2], beside: .right)
        let tabID = try #require(store.currentTab).id

        store.close(agents[1].id)

        #expect(store.currentTab?.id == tabID)
        #expect(store.currentTab?.agentIDs == [agents[0].id, agents[2].id])
        #expect(store.currentTab?.focused == agents[2].id)
        store.close(agents[2].id)
        #expect(store.currentTab?.focused == agents[0].id)
        #expect(store.currentTab?.isSplit == false)
        store.closeTab(tabID)
        #expect(store.tabs.isEmpty)
        #expect(store.sessions.isEmpty)
        #expect(store.selectedTab == HerdrStore.boardID)
    }

    @Test func gatheringFourTabsMakesAGrid() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let agents = ["a", "b", "c", "d"].map { agent("Codex", pane: $0) }
        for agent in agents { store.open(agent) }
        let first = store.tabs[0].id

        store.gatherAll(into: first)

        let tab = try #require(store.currentTab)
        #expect(store.tabs.count == 1)
        #expect(tab.id == first)
        #expect(HerdrArrangement.matching(tab.layout) == .grid)
        #expect(Set(tab.agentIDs) == Set(agents.map(\.id)))
    }

    @Test func mergingFlowsIntoTheCurrentArrangement() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let agents = ["a", "b", "c", "d", "e"].map { agent("Codex", pane: $0) }
        for agent in agents.prefix(4) { store.open(agent) }
        let first = store.tabs[0].id
        store.gatherAll(into: first)
        store.open(agents[4])
        let extra = try #require(store.currentTab).id

        store.merge(extra, into: first)

        let tab = try #require(store.currentTab)
        #expect(tab.agentIDs.count == 5)
        #expect(HerdrArrangement.matching(tab.layout) == .grid)
        #expect(tab.focused == agents[4].id)
    }

    @Test func closingTheFocusedTabInASplitClosesOnlyTheFocusedAgent() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        let opencode = agent("OpenCode", pane: "c")
        store.open(claude)
        store.open(codex, beside: .right)
        store.open(opencode, beside: .right)
        let tabID = try #require(store.currentTab).id
        store.focus(codex.id)

        #expect(store.closeFocusedTab())

        let tab = try #require(store.currentTab)
        #expect(tab.id == tabID)
        #expect(tab.agentIDs == [claude.id, opencode.id])
        #expect(store.sessions.map(\.id) == [claude.id, opencode.id])
        #expect(tab.focused != codex.id)
    }

    @Test func closingTheLastAgentOfASplitClosesTheTab() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        store.open(codex, beside: .right)

        #expect(store.closeFocusedTab())
        #expect(store.currentTab?.agentIDs == [claude.id])
        #expect(store.currentTab?.isSplit == false)

        #expect(store.closeFocusedTab())
        #expect(store.tabs.isEmpty)
        #expect(store.selectedTab == HerdrStore.boardID)
    }

    @Test func separatingGivesEveryAgentItsOwnTab() {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        store.open(codex, beside: .right)
        let tabID = store.currentTab?.id ?? ""

        store.separate(tabID)

        #expect(store.tabs.count == 2)
        #expect(store.tabs.allSatisfy { !$0.isSplit })
        #expect(store.currentTab?.focused == codex.id)
    }

    @Test func arrangingPutsTheFocusedAgentInTheMainSpot() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let agents = ["a", "b", "c"].map { agent("Codex", pane: $0) }
        store.open(agents[0])
        store.open(agents[1], beside: .right)
        store.open(agents[2], beside: .right)
        store.focus(agents[1].id)
        let tabID = try #require(store.currentTab).id

        store.arrange(tabID, as: .focusLeft)

        let frames = try #require(store.currentTab).layout.frames(
            in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let main = try #require(frames[agents[1].id])
        #expect(main.minX == 0)
        #expect(main.height == 100)
        #expect(main.width > 50)
    }

    @Test func zoomFollowsTheAgentAndClearsWhenItLeaves() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        store.toggleZoom(claude.id)
        #expect(store.currentTab?.zoomed == nil)

        store.open(codex, beside: .right)
        store.toggleZoom(claude.id)
        #expect(store.currentTab?.zoomed == claude.id)
        #expect(store.currentTab?.focused == claude.id)

        store.moveToNewTab(claude.id)
        #expect(store.tabs.allSatisfy { $0.zoomed == nil })
    }

    @Test func keyboardFocusMovesAcrossTheLayout() {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        let opencode = agent("OpenCode", pane: "c")
        store.open(claude)
        store.open(codex, beside: .right)
        store.open(opencode, beside: .bottom)

        store.focusNeighbor(toward: .top)
        #expect(store.currentTab?.focused == codex.id)
        store.focusNeighbor(toward: .left)
        #expect(store.currentTab?.focused == claude.id)
        store.focusNeighbor(toward: .left)
        #expect(store.currentTab?.focused == claude.id)
    }

    @Test func layoutKeysResolveTheTerminalStyleChords() {
        #expect(
            HerdrLayoutKey.resolve(keyCode: 123, modifiers: [.command, .option]) == .focus(.left))
        #expect(
            HerdrLayoutKey.resolve(keyCode: 126, modifiers: [.command, .option]) == .focus(.top))
        #expect(HerdrLayoutKey.resolve(keyCode: 36, modifiers: [.command, .shift]) == .zoom)
        #expect(HerdrLayoutKey.resolve(keyCode: 123, modifiers: [.command]) == nil)
        #expect(HerdrLayoutKey.resolve(keyCode: 36, modifiers: [.command]) == nil)
        #expect(HerdrLayoutKey.resolve(keyCode: 50, modifiers: .option) == .cycle(backwards: false))
        #expect(
            HerdrLayoutKey.resolve(keyCode: 50, modifiers: [.option, .shift])
                == .cycle(backwards: true))
        #expect(HerdrLayoutKey.resolve(keyCode: 50, modifiers: .command) == nil)
    }

    @Test func layoutKeysOnlyActInTheWindowShowingHerdr() {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        store.open(codex, beside: .right)
        let page = NSWindow()
        let other = NSWindow()
        store.movePage(from: nil, to: page)

        #expect(!store.performLayoutKey(keyCode: 123, modifiers: [.command, .option], in: other))
        #expect(store.currentTab?.focused == codex.id)
        #expect(store.performLayoutKey(keyCode: 123, modifiers: [.command, .option], in: page))
        #expect(store.currentTab?.focused == claude.id)
        #expect(store.performLayoutKey(keyCode: 36, modifiers: [.command, .shift], in: page))
        #expect(store.currentTab?.zoomed == claude.id)
        store.moveToNewTab(codex.id)
        #expect(!store.performLayoutKey(keyCode: 124, modifiers: [.command, .option], in: page))
    }

    @Test func addingAnAgentKeepsTheFocusedPaneInTheBigSpot() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let agents = ["a", "b", "c", "d"].map { agent("Codex", pane: $0) }
        store.open(agents[0])
        store.open(agents[1], beside: .right)
        store.open(agents[2], beside: .right)
        store.focus(agents[0].id)
        let tabID = try #require(store.currentTab).id
        store.arrange(tabID, as: .focusRight)
        store.open(agents[3])
        let extra = try #require(store.currentTab).id

        store.merge(extra, into: tabID)

        let tab = try #require(store.tab(tabID))
        let frames = tab.layout.frames(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(HerdrArrangement.matching(tab.layout) == .focusRight)
        #expect(frames[agents[0].id]?.maxX == 100)
        #expect(frames[agents[0].id]?.height == 100)
    }

    @Test func layoutKeysFollowEveryWindowShowingHerdr() {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        store.open(agent("Claude Code", pane: "a"))
        store.open(agent("Codex", pane: "b"), beside: .right)
        let main = NSWindow()
        let section = NSWindow()
        store.movePage(from: nil, to: main)
        store.movePage(from: nil, to: section)
        store.movePage(from: section, to: nil)

        #expect(store.performLayoutKey(keyCode: 123, modifiers: [.command, .option], in: main))
        #expect(!store.performLayoutKey(keyCode: 124, modifiers: [.command, .option], in: section))
    }

    @Test func openingBesideTakesAnAgentBackFromItsWindow() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        _ = store.detachedTab(for: codex)

        store.open(codex, beside: .right)
        store.setView(.diff, for: codex.id)

        #expect(store.detachedIDs.isEmpty)
        #expect(store.currentTab?.agentIDs == [claude.id, codex.id])
        #expect(store.session(codex.id)?.view == .diff)
    }

    @Test func optionBacktickCyclesFocusThroughThePanes() {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let agents = ["a", "b", "c"].map { agent("Codex", pane: $0) }
        store.open(agents[0])
        store.open(agents[1], beside: .right)
        store.open(agents[2], beside: .bottom)
        let page = NSWindow()
        store.movePage(from: nil, to: page)

        #expect(store.performLayoutKey(keyCode: 50, modifiers: .option, in: page))
        #expect(store.currentTab?.focused == agents[0].id)
        store.cycleFocus(backwards: false)
        #expect(store.currentTab?.focused == agents[1].id)
        #expect(store.performLayoutKey(keyCode: 50, modifiers: [.option, .shift], in: page))
        #expect(store.currentTab?.focused == agents[0].id)
        store.cycleFocus(backwards: true)
        #expect(store.currentTab?.focused == agents[2].id)
    }

    @Test func reopeningAnAgentInASharedTabFocusesIt() {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        store.open(codex, beside: .right)
        store.selectBoard()

        store.open(claude)

        #expect(store.tabs.count == 1)
        #expect(store.currentTab?.focused == claude.id)
    }

    @Test func swappingKeepsTheShape() throws {
        let store = HerdrStore(defaults: Self.scratchDefaults())
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude)
        store.open(codex, beside: .right)

        store.swap(claude.id, codex.id)

        #expect(store.currentTab?.agentIDs == [codex.id, claude.id])
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "HerdrTabLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func agent(_ kind: String, pane: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: pane, kind: kind, status: .idle, title: kind,
            workspace: "", cwd: "")
    }
}
