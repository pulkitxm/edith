import CoreGraphics
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct HerdrSavedLayoutTests {
    private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func shapesKeepTheGeometryAndRefillInReadingOrder() {
        let layout = HerdrLayout.group(
            .horizontal, [.pane("x"), .stack(.vertical, ["y", "z"])], ratios: [0.7, 0.3])
        let shape = layout.shape()
        #expect(shape.panes == ["0", "1", "2"])
        let refilled = shape.filled(with: ["a", "b", "c"])
        #expect(refilled.panes == ["a", "b", "c"])
        #expect(refilled.geometryMatches(layout))
    }

    @Test func savedLayoutsAreOfferedForTheSameCountAndSurviveARelaunch() throws {
        let defaults = Self.scratchDefaults()
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        let tabID = try threeAgentTab(in: store)
        let tab = try #require(store.tab(tabID))
        guard case let .split(split) = tab.layout else {
            Issue.record("expected a split")
            return
        }
        store.resize(tabID, split: split.id, index: 0, by: 0.2)

        let saved = try #require(store.saveArrangement(of: tabID, named: "  Review  "))

        #expect(saved.name == "Review")
        #expect(store.templates(for: 3).first == .saved(saved))
        #expect(!store.templates(for: 2).contains(.saved(saved)))
        #expect(store.currentTemplate(of: tabID) == .saved(saved))
        let relaunched = HerdrStore(
            defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        #expect(relaunched.savedArrangements == [saved])
    }

    @Test func applyingASavedLayoutPutsTheFocusedAgentFirst() throws {
        let store = HerdrStore(
            defaults: Self.scratchDefaults(), liveWatcher: { _ in }, machinesProvider: { [] })
        let tabID = try threeAgentTab(in: store)
        let saved = try #require(store.saveArrangement(of: tabID, named: "Mine"))
        store.arrange(tabID, as: .rows)
        let focused = try #require(store.tab(tabID)).focused

        store.arrange(tabID, as: .saved(saved))

        let tab = try #require(store.tab(tabID))
        #expect(tab.agentIDs.first == focused)
        #expect(tab.layout.geometryMatches(saved.shape))
    }

    @Test func savingTheSameShapeAgainReplacesIt() throws {
        let store = HerdrStore(
            defaults: Self.scratchDefaults(), liveWatcher: { _ in }, machinesProvider: { [] })
        let tabID = try threeAgentTab(in: store)
        store.saveArrangement(of: tabID, named: "First")
        let second = try #require(store.saveArrangement(of: tabID, named: "Second"))

        #expect(store.savedArrangements == [second])
        store.deleteArrangement(second.id)
        #expect(store.savedArrangements.isEmpty)
    }

    @Test func everyUseOfASavedLayoutGetsItsOwnSplits() throws {
        let store = HerdrStore(
            defaults: Self.scratchDefaults(), liveWatcher: { _ in }, machinesProvider: { [] })
        let first = try threeAgentTab(in: store)
        let saved = try #require(store.saveArrangement(of: first, named: "Mine"))
        store.open(agent("d"))
        store.open(agent("e"), beside: .right)
        store.open(agent("f"), beside: .right)
        let second = try #require(store.currentTab).id
        store.arrange(first, as: .saved(saved))
        store.arrange(second, as: .saved(saved))

        let firstIDs = try #require(store.tab(first)).layout.splitIDs
        let secondIDs = try #require(store.tab(second)).layout.splitIDs
        #expect(Set(firstIDs).isDisjoint(with: secondIDs))
        #expect(Set(firstIDs).isDisjoint(with: saved.shape.splitIDs))

        store.selectedTab = first
        store.drop(.tab(second), on: .edge(agent("a").id, .left))
        let merged = try #require(store.tab(first)).layout.splitIDs
        #expect(Set(merged).count == merged.count)
    }

    @Test func draggingOntoASavedSlotUsesThatShape() throws {
        let store = HerdrStore(
            defaults: Self.scratchDefaults(), liveWatcher: { _ in }, machinesProvider: { [] })
        let tabID = try threeAgentTab(in: store)
        let saved = try #require(store.saveArrangement(of: tabID, named: "Mine"))
        store.close(agent("c").id)

        store.drop(.agent(agent("d")), on: .slot(.saved(saved), 2))

        let tab = try #require(store.tab(tabID))
        #expect(tab.agentIDs == [agent("a").id, agent("b").id, agent("d").id])
        #expect(tab.layout.geometryMatches(saved.shape))
    }

    private func threeAgentTab(in store: HerdrStore) throws -> String {
        store.open(agent("a"))
        store.open(agent("b"), beside: .right)
        store.open(agent("c"), beside: .bottom)
        return try #require(store.currentTab).id
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "HerdrSavedLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func agent(_ pane: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: pane, kind: "Codex", status: .idle, title: pane,
            workspace: "", cwd: "")
    }
}
