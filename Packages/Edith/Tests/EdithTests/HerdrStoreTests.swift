import EdithKit
import Testing

@testable import Edith

@MainActor
@Suite struct HerdrStoreTests {
    @Test func kindPillsAccumulateLikeCheckboxes() {
        let store = HerdrStore()
        store.selectKind("Claude Code", exclusive: false)
        store.selectKind("Codex", exclusive: false)
        #expect(store.kindFilter == ["Claude Code", "Codex"])
        #expect(store.kindIsSelected("Claude Code"))
        #expect(!store.kindIsSelected("all"))
        store.selectKind("Claude Code", exclusive: false)
        #expect(store.kindFilter == ["Codex"])
        store.selectKind("Codex", exclusive: false)
        #expect(store.kindFilter.isEmpty)
        #expect(store.kindIsSelected("all"))
    }

    @Test func commandClickKeepsOnlyThatKind() {
        let store = HerdrStore()
        store.selectKind("Claude Code", exclusive: false)
        store.selectKind("Codex", exclusive: false)
        store.selectKind("OpenCode", exclusive: true)
        #expect(store.kindFilter == ["OpenCode"])
        store.selectKind("all", exclusive: true)
        #expect(store.kindFilter.isEmpty)
    }

    @Test func closeOthersKeepsTheClickedTab() {
        let store = seededStore()
        let keep = store.tabs[1].id
        store.selectedTab = store.tabs[0].id
        store.closeOthers(besides: keep)
        #expect(store.tabs.map(\.id) == [keep])
        #expect(store.selectedTab == keep)
    }

    @Test func closeToTheRightDropsLaterTabs() {
        let store = seededStore()
        let first = store.tabs[0].id
        store.selectedTab = store.tabs[2].id
        store.closeToTheRight(of: first)
        #expect(store.tabs.map(\.id) == [first])
        #expect(store.selectedTab == first)
        store.closeToTheRight(of: HerdrStore.boardID)
        #expect(store.tabs.isEmpty)
        #expect(store.selectedTab == HerdrStore.boardID)
    }

    @Test func closeToTheLeftDropsEarlierTabs() {
        let store = seededStore()
        let last = store.tabs[2].id
        store.closeToTheLeft(of: last)
        #expect(store.tabs.map(\.id) == [last])
        #expect(store.canCloseToTheLeft(of: last) == false)
        #expect(store.canCloseToTheRight(of: last) == false)
    }

    private func seededStore() -> HerdrStore {
        let store = HerdrStore()
        store.tabs = [
            HerdrOpenTab(
                agent: agent("Claude Code", pane: "a"), machine: nil,
                holder: TerminalSessionHolder()),
            HerdrOpenTab(
                agent: agent("Codex", pane: "b"), machine: nil, holder: TerminalSessionHolder()),
            HerdrOpenTab(
                agent: agent("OpenCode", pane: "c"), machine: nil, holder: TerminalSessionHolder()),
        ]
        store.selectedTab = store.tabs[2].id
        return store
    }

    @Test func multipleKindsPassTheBoardFilter() {
        let store = HerdrStore()
        store.hosts = [
            .local(
                herdrPresent: true,
                agents: [
                    agent("Claude Code", pane: "a"),
                    agent("Codex", pane: "b"),
                    agent("OpenCode", pane: "c"),
                ])
        ]
        store.selectKind("Claude Code", exclusive: false)
        store.selectKind("OpenCode", exclusive: false)
        #expect(Set(store.filteredAgents.map(\.kind)) == ["Claude Code", "OpenCode"])
    }

    @Test func applyReplacesHostsAndOpenTabAgents() {
        let store = seededStore()
        let updated = agent("Claude Code", pane: "a")
        store.apply([
            .local(herdrPresent: true, agents: [updated])
        ])
        #expect(store.hosts.first?.agents.map(\.id) == [updated.id])
        #expect(store.tabs.contains { $0.agent.id == updated.id && $0.agent.kind == "Claude Code" })
    }

    private func agent(_ kind: String, pane: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: pane, kind: kind, status: .idle, title: kind,
            workspace: "", cwd: "")
    }
}
