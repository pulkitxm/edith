import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite struct HerdrSessionFilterTests {
    @Test func noFiltersProduceNoChips() {
        let chips = HerdrSessionFilters.chips(
            machineID: "all", machineName: "All machines", kinds: [], groupsBySpace: false)
        #expect(chips.isEmpty)
        #expect(HerdrSessionFilters.summary(of: chips) == "No filters")
    }

    @Test func activeFiltersBecomeRemovableChips() {
        let chips = HerdrSessionFilters.chips(
            machineID: "local",
            machineName: "This Mac",
            kinds: ["Codex", "Claude Code"],
            groupsBySpace: true)
        #expect(chips.map(\.key) == ["Machine", "Agent", "Agent", "Group"])
        #expect(chips.map(\.value) == ["This Mac", "Claude Code", "Codex", "Space"])
        #expect(
            chips.map(\.removal) == [.machine, .kind("Claude Code"), .kind("Codex"), .grouping])
        #expect(chips.map(\.removeLabel).first == "Remove machine filter, This Mac")
    }

    @Test func anUnknownMachineNameFallsBackToItsIdentifier() {
        let chips = HerdrSessionFilters.chips(
            machineID: "abc", machineName: "", kinds: [], groupsBySpace: false)
        #expect(chips.map(\.value) == ["abc"])
        #expect(chips.map(\.accessibilityLabel) == ["Machine is abc"])
    }

    @Test func summaryReadsEachActiveFilter() {
        let chips = HerdrSessionFilters.chips(
            machineID: "local", machineName: "This Mac", kinds: ["Codex"], groupsBySpace: true)
        #expect(
            HerdrSessionFilters.summary(of: chips)
                == "Machine is This Mac, Agent is Codex, Grouped by space")
    }

    @Test func menuOffersMachineAgentDisplaySpacesAndActions() {
        let rows = sample(query: "")
        #expect(
            rows.map(\.title) == [
                "All machines", "This Mac", "Build",
                "Any agent", "Codex", "Claude Code",
                "Group by space",
                "edith",
                "Edit launch settings", "Clear filters",
            ])
        #expect(rows.first { $0.id == "machine:local" }?.selected == true)
        #expect(rows.first { $0.id == "machine:all" }?.selected == false)
        #expect(rows.first { $0.id == "agent:Codex" }?.selected == true)
        #expect(rows.first { $0.id == "agent:all" }?.selected == false)
        #expect(rows.first { $0.id == "grouping" }?.selected == true)
        #expect(
            rows.first { $0.action == .space("s1") }?.accessibilityLabel
                == "Open edith in a new window")
    }

    @Test func clearFiltersIsHiddenUntilSomethingIsActive() {
        let rows = HerdrSessionFilters.rows(
            query: "",
            machines: [("all", "All machines")],
            kinds: ["Codex"],
            machineID: "all",
            selectedKinds: [],
            groupsBySpace: false,
            spaces: [])
        #expect(rows.map(\.title).contains("Edit launch settings"))
        #expect(!rows.map(\.title).contains("Clear filters"))
    }

    @Test func aQueryKeepsMatchingRowsAndTheirSection() {
        #expect(sample(query: "codex").map(\.title) == ["Codex"])
        #expect(sample(query: " machine ").map(\.section) == ["Machine", "Machine", "Machine"])
        #expect(sample(query: "space").map(\.title) == ["Group by space", "edith"])
        #expect(sample(query: "zzz").isEmpty)
    }

    @Test func highlightStaysInsideTheMenu() {
        #expect(HerdrSessionFilters.highlight(0, movingBy: -1, count: 3) == 0)
        #expect(HerdrSessionFilters.highlight(1, movingBy: 1, count: 3) == 2)
        #expect(HerdrSessionFilters.highlight(2, movingBy: 4, count: 3) == 2)
        #expect(HerdrSessionFilters.highlight(4, movingBy: 1, count: 0) == 0)
    }

    private func sample(query: String) -> [HerdrSessionFilterRow] {
        HerdrSessionFilters.rows(
            query: query,
            machines: [("all", "All machines"), ("local", "This Mac"), ("remote", "Build")],
            kinds: ["Codex", "Claude Code"],
            machineID: "local",
            selectedKinds: ["Codex"],
            groupsBySpace: true,
            spaces: [("s1", "edith")])
    }
}

@MainActor
@Suite struct HerdrSessionFilterStoreTests {
    @Test func clearingRemovesMachineKindAndGrouping() {
        let store = makeStore()
        store.machineFilter = "local"
        store.selectKind("Codex", exclusive: false)
        store.spaceGroupingEnabled = true
        store.clearSessionFilters()
        #expect(store.machineFilter == "all")
        #expect(store.kindFilter.isEmpty)
        #expect(!store.spaceGroupingEnabled)
    }

    @Test func aMachineFilterThatMatchesNothingStaysEmpty() {
        let store = makeStore()
        let local = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "s", pane: "p1", kind: "Codex", status: .idle, title: "Local",
            workspace: "w", cwd: "/tmp")
        let remote = HerdrAgent.make(
            machineID: "remote", machineName: "Build", machineIsLocal: false, sshTarget: "build",
            session: "s", pane: "p2", kind: "Codex", status: .idle, title: "Remote",
            workspace: "w", cwd: "/tmp")
        store.apply([
            .local(herdrPresent: true, agents: [local]),
            HerdrHostSnapshot(
                id: "remote", name: "Build", isLocal: false, sshTarget: "build",
                herdrPresent: true, reachable: true, agents: [remote]),
        ])
        store.machineFilter = "remote"
        #expect(store.listedAgents.map(\.id) == [remote.id])
        store.machineFilter = "missing"
        #expect(store.listedAgents.isEmpty)
        store.machineFilter = "all"
        store.selectKind("Claude Code", exclusive: false)
        #expect(store.listedAgents.isEmpty)
    }

    private func makeStore() -> HerdrStore {
        HerdrStore(
            defaults: UserDefaults(suiteName: "herdr.filters.\(UUID().uuidString)")!,
            liveWatcher: { _ in })
    }
}
