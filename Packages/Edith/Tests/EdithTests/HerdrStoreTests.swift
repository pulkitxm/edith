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

    private func agent(_ kind: String, pane: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: pane, kind: kind, status: .idle, title: kind,
            workspace: "", cwd: "")
    }
}
