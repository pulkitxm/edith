import CoreGraphics
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct HerdrDropTests {
    private let canvas = CGRect(x: 300, y: 100, width: 800, height: 600)

    private var geometry: HerdrDropGeometry {
        HerdrDropGeometry(
            page: CGRect(x: 0, y: 0, width: 1400, height: 800),
            tabBar: CGRect(x: 0, y: 50, width: 1400, height: 40),
            canvas: canvas,
            chips: [
                HerdrTabChip(
                    id: HerdrStore.boardID, frame: CGRect(x: 60, y: 55, width: 80, height: 30)),
                HerdrTabChip(id: "one", frame: CGRect(x: 150, y: 55, width: 100, height: 30)),
                HerdrTabChip(id: "two", frame: CGRect(x: 260, y: 55, width: 100, height: 30)),
            ])
    }

    @Test func pointerNearAPaneEdgeSplitsThatSide() {
        let tab = HerdrTab(agentID: "a")
        let target = { (point: CGPoint) in
            HerdrDropResolver.target(
                at: point, geometry: geometry, tab: tab, boardID: HerdrStore.boardID,
                snapBar: nil, previous: nil, gap: 6)
        }
        #expect(target(CGPoint(x: 1080, y: 400)) == .edge("a", .right))
        #expect(target(CGPoint(x: 320, y: 400)) == .edge("a", .left))
        #expect(target(CGPoint(x: 700, y: 690)) == .edge("a", .bottom))
        #expect(target(CGPoint(x: 700, y: 400)) == .center("a"))
    }

    @Test func edgesStickUntilThePointerClearlyLeaves() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let entering = HerdrDropResolver.paneTarget(
            id: "a", frame: frame, point: CGPoint(x: 70, y: 50), previous: nil)
        #expect(entering == .center("a"))
        let sticky = HerdrDropResolver.paneTarget(
            id: "a", frame: frame, point: CGPoint(x: 70, y: 50), previous: .edge("a", .right))
        #expect(sticky == .edge("a", .right))
        let left = HerdrDropResolver.paneTarget(
            id: "a", frame: frame, point: CGPoint(x: 55, y: 50), previous: .edge("a", .right))
        #expect(left == .center("a"))
    }

    @Test func theOuterBandSpansTheWholeSideOfASplitTab() {
        var tab = HerdrTab(agentID: "a")
        tab.layout = .stack(.horizontal, ["a", "b"])
        let target = HerdrDropResolver.target(
            at: CGPoint(x: 700, y: canvas.maxY - 5), geometry: geometry, tab: tab,
            boardID: HerdrStore.boardID, snapBar: nil, previous: nil, gap: 6)
        #expect(target == .outerEdge(.bottom))
    }

    @Test func theTabBarOffersInsertionAndMerging() {
        let target = { (x: CGFloat) in
            HerdrDropResolver.target(
                at: CGPoint(x: x, y: 70), geometry: geometry, tab: nil,
                boardID: HerdrStore.boardID, snapBar: nil, previous: nil, gap: 6)
        }
        #expect(target(100) == .tabBar(0))
        #expect(target(155) == .tabBar(0))
        #expect(target(200) == .intoTab("one"))
        #expect(target(245) == .tabBar(1))
        #expect(target(310) == .intoTab("two"))
        #expect(target(900) == .tabBar(2))
    }

    @Test func leavingThePageTearsOffAndTheBoardOpensATab() {
        let outside = HerdrDropResolver.target(
            at: CGPoint(x: 1500, y: 400), geometry: geometry, tab: nil,
            boardID: HerdrStore.boardID, snapBar: nil, previous: nil, gap: 6)
        #expect(outside == .window)
        let board = HerdrDropResolver.target(
            at: CGPoint(x: 700, y: 400), geometry: geometry, tab: nil,
            boardID: HerdrStore.boardID, snapBar: nil, previous: nil, gap: 6)
        #expect(board == .newTab)
    }

    @Test func theSnapBarExpandsNearTheTopAndPicksASlot() throws {
        let far = try #require(
            HerdrSnapBar.make(
                count: 3, canvas: canvas, pointer: CGPoint(x: 700, y: 500), unit: 1,
                wasExpanded: false))
        #expect(!far.expanded)
        let near = try #require(
            HerdrSnapBar.make(
                count: 3, canvas: canvas, pointer: CGPoint(x: 700, y: 130), unit: 1,
                wasExpanded: false))
        #expect(near.expanded)
        #expect(near.thumbnails.map(\.arrangement) == HerdrArrangement.options(for: 3))
        let thumbnail = try #require(near.thumbnails.first)
        let slot = try #require(thumbnail.slots.last)
        let picked = try #require(near.slot(at: CGPoint(x: slot.midX, y: slot.midY)))
        #expect(picked.0 == thumbnail.arrangement)
        #expect(picked.1 == thumbnail.slots.count - 1)
        var tab = HerdrTab(agentID: "a")
        tab.layout = .stack(.horizontal, ["a", "b"])
        let target = HerdrDropResolver.target(
            at: CGPoint(x: slot.midX, y: slot.midY), geometry: geometry, tab: tab,
            boardID: HerdrStore.boardID, snapBar: near, previous: nil, gap: 6)
        #expect(target == .slot(thumbnail.arrangement, thumbnail.slots.count - 1))
    }

    @Test func droppingARailAgentOnAnEdgeOpensItBeside() throws {
        let store = makeStore()
        store.open(claude)
        let tabID = try #require(store.currentTab).id

        store.drop(.agent(codex), on: .edge(claude.id, .right))

        let tab = try #require(store.currentTab)
        #expect(tab.id == tabID)
        #expect(tab.agentIDs == [claude.id, codex.id])
        #expect(tab.focused == codex.id)
        #expect(store.sessions.count == 2)
    }

    @Test func droppingAnOpenTabOnAnEdgeMovesItIn() throws {
        let store = makeStore()
        store.open(claude)
        let tabID = try #require(store.currentTab).id
        store.open(codex)
        let codexTab = try #require(store.currentTab).id
        store.selectedTab = tabID

        store.drop(.tab(codexTab), on: .edge(claude.id, .bottom))

        #expect(store.tabs.map(\.id) == [tabID])
        #expect(store.currentTab?.agentIDs == [claude.id, codex.id])
        #expect(store.currentTab?.layout.frames(in: canvas)[codex.id]?.minY == canvas.midY)
    }

    @Test func centreDropsSwapOrReplace() throws {
        let store = makeStore()
        store.open(claude)
        store.open(codex, beside: .right)
        store.drop(.agent(claude), on: .center(codex.id))
        #expect(store.currentTab?.agentIDs == [codex.id, claude.id])

        store.drop(.agent(opencode), on: .center(codex.id))
        #expect(store.tabs.count == 2)
        #expect(store.currentTab?.agentIDs == [opencode.id, claude.id])
        #expect(store.tabs[1].agentIDs == [codex.id])
    }

    @Test func centreDropsAcrossTabsSwapPlaces() throws {
        let store = makeStore()
        store.open(claude)
        store.open(codex, beside: .right)
        let shared = try #require(store.currentTab).id
        store.open(opencode)
        let single = try #require(store.currentTab).id
        store.selectedTab = shared

        store.drop(.agent(opencode), on: .center(claude.id))

        #expect(store.tab(shared)?.agentIDs == [opencode.id, codex.id])
        #expect(store.tab(single)?.agentIDs == [claude.id])
    }

    @Test func slotsPlaceTheAgentIntoTheChosenArrangement() throws {
        let store = makeStore()
        store.open(claude)
        store.open(codex, beside: .right)

        store.drop(.agent(opencode), on: .slot(.focusLeft, 0))

        let tab = try #require(store.currentTab)
        #expect(tab.agentIDs.first == opencode.id)
        let frames = tab.layout.frames(in: canvas)
        #expect(frames[opencode.id]?.height == canvas.height)
        #expect((frames[opencode.id]?.width ?? 0) > canvas.width / 2)
    }

    @Test func tabBarDropsPullAPaneIntoItsOwnTab() throws {
        let store = makeStore()
        store.open(claude)
        store.open(codex, beside: .right)
        let shared = try #require(store.currentTab).id

        store.drop(.agent(codex), on: .tabBar(0))

        #expect(store.tabs.count == 2)
        #expect(store.tabs[0].agentIDs == [codex.id])
        #expect(store.tab(shared)?.agentIDs == [claude.id])
        #expect(store.currentTab?.id == store.tabs[0].id)
    }

    @Test func tabBarDropsReorderTabs() {
        let store = makeStore()
        store.open(claude)
        store.open(codex)
        store.open(opencode)
        let ids = store.tabs.map(\.id)
        #expect(!store.accepts(.tab(ids[0]), .tabBar(0)))
        #expect(!store.accepts(.tab(ids[0]), .tabBar(1)))

        store.drop(.tab(ids[0]), on: .tabBar(3))

        #expect(store.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func droppingOnAChipAddsToThatTab() throws {
        let store = makeStore()
        store.open(claude)
        let first = try #require(store.currentTab).id
        store.open(codex)

        store.drop(.agent(opencode), on: .intoTab(first))

        #expect(store.currentTab?.id == first)
        #expect(store.currentTab?.agentIDs == [claude.id, opencode.id])
        #expect(!store.accepts(.agent(claude), .intoTab(first)))
        #expect(!store.accepts(.tab(first), .intoTab(first)))
    }

    @Test func draggingAPaneOntoItselfIsRefused() {
        let store = makeStore()
        store.open(claude)
        store.open(codex, beside: .right)
        #expect(!store.accepts(.agent(codex), .edge(codex.id, .left)))
        #expect(!store.accepts(.agent(codex), .center(codex.id)))
        #expect(store.accepts(.agent(codex), .edge(claude.id, .bottom)))
        store.open(opencode)
        #expect(!store.accepts(.agent(opencode), .edge(opencode.id, .left)))
        #expect(store.snapCount(for: .agent(opencode)) == nil)
    }

    @Test func splitTabsKeepTheirShapeWhenDroppedBeside() throws {
        let store = makeStore()
        store.open(claude)
        let target = try #require(store.currentTab).id
        store.open(codex)
        store.open(opencode, beside: .bottom)
        let group = try #require(store.currentTab).id
        store.selectedTab = target

        store.drop(.tab(group), on: .edge(claude.id, .right))

        let tab = try #require(store.currentTab)
        #expect(store.tabs.map(\.id) == [target])
        let frames = tab.layout.frames(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(frames[codex.id] == CGRect(x: 50, y: 0, width: 50, height: 50))
        #expect(frames[opencode.id] == CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    private let claude = agent("Claude Code", pane: "a")
    private let codex = agent("Codex", pane: "b")
    private let opencode = agent("OpenCode", pane: "c")

    private func makeStore() -> HerdrStore {
        let suite = "HerdrDropTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
    }
}

private func agent(_ kind: String, pane: String) -> HerdrAgent {
    HerdrAgent.make(
        machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
        session: "default", pane: pane, kind: kind, status: .idle, title: kind,
        workspace: "", cwd: "")
}
