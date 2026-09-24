import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct HerdrDragFlowTests {
    @Test func draggingARailAgentOntoAPaneEdgeSplitsIt() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.open(page.agents[0])
        await page.settle()
        let pane = try page.paneFrame(page.agents[0].id)

        page.drag(
            .agent(page.agents[1]), from: CGPoint(x: 80, y: 400),
            to: CGPoint(x: pane.maxX - 20, y: pane.midY))

        #expect(page.store.currentTab?.agentIDs == [page.agents[0].id, page.agents[1].id])
        #expect(page.drag.item == nil)
    }

    @Test func thePreviewMatchesTheLayoutThatLands() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.open(page.agents[0])
        page.store.open(page.agents[1], beside: .right)
        await page.settle()
        let pane = try page.paneFrame(page.agents[1].id)
        let point = CGPoint(x: pane.midX, y: pane.maxY - 30)

        page.drag.update(.agent(page.agents[2]), at: CGPoint(x: 80, y: 400))
        page.drag.update(.agent(page.agents[2]), at: point)
        let target = try #require(page.drag.target)
        let preview = page.store.proposedLayout(.agent(page.agents[2]), target)
        page.drag.finish(.agent(page.agents[2]), at: point)

        #expect(target == .edge(page.agents[1].id, .bottom))
        let unit = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(page.store.currentTab?.layout.frames(in: unit) == preview?.frames(in: unit))
    }

    @Test func draggingATabChipToTheEndReordersTheTabs() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        for agent in page.agents { page.store.open(agent) }
        await page.settle()
        let ids = page.store.tabs.map(\.id)
        let first = try page.chip(ids[0])
        let last = try page.chip(ids[2])

        page.drag(
            .tab(ids[0]), from: CGPoint(x: first.midX, y: first.midY),
            to: CGPoint(x: last.maxX - 4, y: last.midY))

        #expect(page.store.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func holdingOverATabSpringsItOpen() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.open(page.agents[0])
        let first = try #require(page.store.currentTab).id
        page.store.open(page.agents[1])
        await page.settle()
        let chip = try page.chip(first)

        page.drag.update(.agent(page.agents[2]), at: CGPoint(x: 80, y: 400))
        page.drag.update(.agent(page.agents[2]), at: CGPoint(x: chip.midX, y: chip.midY))
        #expect(page.drag.target == .intoTab(first))
        try await Task.sleep(for: HerdrDragCoordinator.springDelay + .milliseconds(250))
        #expect(page.store.selectedTab == first)

        let pane = try page.paneFrame(page.agents[0].id)
        page.drag.update(.agent(page.agents[2]), at: CGPoint(x: pane.minX + 12, y: pane.midY))
        page.drag.finish(.agent(page.agents[2]), at: CGPoint(x: pane.minX + 12, y: pane.midY))
        #expect(page.store.currentTab?.agentIDs == [page.agents[2].id, page.agents[0].id])
    }

    @Test func nearingTheTopOffersArrangements() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.open(page.agents[0])
        page.store.open(page.agents[1], beside: .right)
        await page.settle()
        let canvas = try page.canvas()

        page.drag.update(.agent(page.agents[2]), at: CGPoint(x: canvas.midX, y: canvas.midY))
        #expect(page.drag.snapBar?.expanded == false)
        page.drag.update(.agent(page.agents[2]), at: CGPoint(x: canvas.midX, y: canvas.minY + 30))
        let bar = try #require(page.drag.snapBar)
        #expect(bar.expanded)
        #expect(bar.thumbnails.count == HerdrArrangement.options(for: 3).count)
        let grid = try #require(bar.thumbnails.first { $0.template == .builtIn(.focusRight) })
        let slot = grid.slots[0]
        page.drag.update(.agent(page.agents[2]), at: CGPoint(x: slot.midX, y: slot.midY))
        page.drag.finish(.agent(page.agents[2]), at: CGPoint(x: slot.midX, y: slot.midY))

        let tab = try #require(page.store.currentTab)
        #expect(HerdrArrangement.matching(tab.layout) == .focusRight)
        #expect(tab.focused == page.agents[2].id)
    }

    @Test func releasingOutsideThePageTearsTheAgentOff() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.open(page.agents[0])
        await page.settle()
        var torn: HerdrAgent?
        page.drag.onTearOff = { torn = $0 }

        page.drag(.agent(page.agents[0]), from: CGPoint(x: 80, y: 400), to: CGPoint(x: -40, y: 400))

        #expect(torn?.id == page.agents[0].id)
    }

    @Test func aShortWobbleNeverDrops() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.selectBoard()
        await page.settle()
        let canvas = try page.canvas()
        let start = CGPoint(x: canvas.midX, y: canvas.midY)

        page.drag.update(.agent(page.agents[0]), at: start, from: start)
        page.drag.finish(
            .agent(page.agents[0]), at: CGPoint(x: start.x + 8, y: start.y), from: start)

        #expect(page.store.tabs.isEmpty)
    }

    @Test func aNewGestureReplacesAStaleOne() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.open(page.agents[0])
        await page.settle()
        let pane = try page.paneFrame(page.agents[0].id)
        let edge = CGPoint(x: pane.maxX - 20, y: pane.midY)

        page.drag.update(.agent(page.agents[2]), at: edge, from: CGPoint(x: 80, y: 300))
        page.drag.cancel()
        page.drag.update(.agent(page.agents[1]), at: edge, from: CGPoint(x: 80, y: 420))
        page.drag.finish(.agent(page.agents[1]), at: edge, from: CGPoint(x: 80, y: 420))

        #expect(page.store.currentTab?.agentIDs == [page.agents[0].id, page.agents[1].id])
    }

    @Test func escapeCancelsADragInFlight() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        page.store.open(page.agents[0])
        await page.settle()
        let pane = try page.paneFrame(page.agents[0].id)
        let point = CGPoint(x: pane.maxX - 20, y: pane.midY)

        page.drag.update(.agent(page.agents[1]), at: point)
        #expect(page.drag.target == .edge(page.agents[0].id, .right))
        page.drag.cancel()
        page.drag.update(.agent(page.agents[1]), at: point)
        page.drag.finish(.agent(page.agents[1]), at: point)

        #expect(page.store.currentTab?.agentIDs == [page.agents[0].id])
        #expect(page.drag.item == nil)
    }
}

@MainActor
final class RenderedHerdrPage {
    let store: HerdrStore
    let drag = HerdrDragCoordinator()
    let agents: [HerdrAgent]
    private let host: NSHostingView<AnyView>
    private let window: NSWindow
    private let suite = "HerdrDragFlowTests-\(UUID().uuidString)"

    init() async throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        agents = ["Alpha task", "Beta task", "Gamma task"].enumerated().map { index, title in
            HerdrAgent.make(
                machineID: "local", machineName: "This Mac", machineIsLocal: true,
                sshTarget: nil, session: "demo", pane: "w1:p\(index + 1)", kind: "Codex",
                status: .idle, title: title, workspace: "demo", cwd: "/tmp/demo")
        }
        store.apply([.local(herdrPresent: true, agents: agents)])
        host = NSHostingView(
            rootView: AnyView(
                HerdrPage(store: store, drag: drag)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.machineConnectionsEnabled, false)
                    .environment(\.terminalLaunchEnabled, false)
                    .transaction { $0.animation = nil }))
        host.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        await settle()
    }

    func settle() async {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func canvas() throws -> CGRect {
        try #require(drag.frames[HerdrDropGeometry.canvasKey])
    }

    func chip(_ id: String) throws -> CGRect {
        try #require(drag.frames[HerdrDropGeometry.chipPrefix + id])
    }

    func paneFrame(_ id: String) throws -> CGRect {
        let tab = try #require(store.tab(containing: id))
        return try #require(
            tab.layout.paneFrames(in: canvas(), gap: UIScale.pt(6))[id])
    }

    func drag(_ item: HerdrDragItem, from start: CGPoint, to end: CGPoint) {
        for step in 0...12 {
            let progress = CGFloat(step) / 12
            drag.update(
                item,
                at: CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress))
        }
        drag.finish(item, at: end)
    }

    func close() {
        store.closeAll()
        window.orderOut(nil)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
