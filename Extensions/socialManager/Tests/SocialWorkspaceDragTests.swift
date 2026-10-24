import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import SwiftUI
import Testing
@testable import SocialManagerExtension

@MainActor @Suite(.serialized)
struct SocialWorkspaceDragTests {
    @Test func profileCardsWithDifferentDetailsShareTopAndBottomEdges() async throws {
        let page = try await RenderedSocialWorkspace()
        defer { page.close() }
        let profiles = page.model.catalog.profiles
        try page.model.saveProfile(
            id: profiles[0].id, name: "Studio", badge: "ST", email: "studio@example.test")
        page.model.profileID = nil
        await page.settle()
        let first = try page.frame("profileCard:" + profiles[0].id.uuidString)
        let second = try page.frame("profileCard:" + profiles[1].id.uuidString)
        #expect(abs(first.minY - second.minY) < 1)
        #expect(abs(first.maxY - second.maxY) < 1)
        try await page.capture("aligned-profile-cards")
    }

    @Test func renderedRailAndTabDropsSplitSwapMergeAndRetainTheSameBrowsers() async throws {
        let page = try await RenderedSocialWorkspace()
        defer { page.close() }
        let model = page.model
        let accounts = model.catalog.accounts
        model.open(accounts[0])
        let firstTab = try #require(model.currentTab)
        let firstSession = try #require(model.sessions[accounts[0].id])
        await page.settle()
        let canvas = try page.frame(HerdrDropGeometry.canvasKey)
        let rail = try page.frame(HerdrDropGeometry.agentPrefix + accounts[2].id.uuidString)
        let right = CGPoint(x: canvas.maxX - 30, y: canvas.midY)
        page.drag.update(.pane(accounts[2].id.uuidString), at: right, from: rail.center)
        #expect(page.drag.target == .edge(accounts[0].id.uuidString, .right))
        #expect(page.drag.snapBar != nil)
        try await page.capture("split-preview")
        page.drag.finish(.pane(accounts[2].id.uuidString), at: right, from: rail.center)
        #expect(model.tabs.count == 1)
        #expect(
            model.currentTab?.layout.panes == [
                accounts[0].id.uuidString, accounts[2].id.uuidString,
            ])
        #expect(model.sessions[accounts[0].id] === firstSession)
        let secondSession = try #require(model.sessions[accounts[2].id])
        await page.settle()
        try await page.capture("split-result")
        let panes = try #require(
            model.currentTab?.layout.paneFrames(in: canvas, gap: UIScale.pt(6)))
        let target = try #require(panes[accounts[0].id.uuidString])
        page.drag.finish(.pane(accounts[2].id.uuidString), at: target.center)
        #expect(
            model.currentTab?.layout.panes == [
                accounts[2].id.uuidString, accounts[0].id.uuidString,
            ])
        model.open(accounts[1])
        let other = try #require(model.currentTab)
        model.select(firstTab)
        await page.settle()
        let chip = try page.frame(HerdrDropGeometry.chipPrefix + firstTab.id.uuidString)
        page.drag.finish(.tab(other.id.uuidString), at: chip.center)
        #expect(model.tabs.count == 1)
        #expect(model.currentTab?.layout.paneCount == 3)
        #expect(model.sessions[accounts[0].id] === firstSession)
        #expect(model.sessions[accounts[2].id] === secondSession)
        #expect(
            Set(model.currentTab?.layout.panes ?? [])
                == Set([accounts[0], accounts[1], accounts[2]].map { $0.id.uuidString }))
        try await page.capture("cross-profile-workspace")
    }

    @Test func paneHeadersAndTabChipsPublishGeometryForDetachingAndReordering() async throws {
        let page = try await RenderedSocialWorkspace()
        defer { page.close() }
        let accounts = page.model.catalog.accounts
        page.model.open(accounts[0])
        let target = try #require(page.model.currentTab)
        page.model.open(accounts[2], beside: true)
        await page.settle()
        let header = try page.frame("paneHeader:" + accounts[2].id.uuidString)
        let bar = try page.frame(HerdrDropGeometry.tabBarKey)
        let end = CGPoint(x: bar.maxX - 70, y: bar.midY)
        page.drag.finish(.pane(accounts[2].id.uuidString), at: end, from: header.center)
        #expect(page.model.tabs.count == 2)
        #expect(page.model.currentTab?.layout.paneCount == 1)
        let detached = try #require(page.model.currentTab)
        await page.settle()
        let chip = try page.frame(HerdrDropGeometry.chipPrefix + target.id.uuidString)
        let beginning = CGPoint(x: chip.minX + 2, y: chip.midY)
        page.drag.finish(.tab(detached.id.uuidString), at: beginning)
        #expect(page.model.tabs.first?.id == detached.id)
    }

    @Test func springLoadedTabsSnapLayoutsAndEscapeUseTheSessionCoordinator() async throws {
        let page = try await RenderedSocialWorkspace()
        defer { page.close() }
        let model = page.model
        let accounts = model.catalog.accounts
        model.open(accounts[0])
        let first = try #require(model.currentTab)
        model.open(accounts[1])
        await page.settle()
        let chip = try page.frame(HerdrDropGeometry.chipPrefix + first.id.uuidString)
        page.drag.update(.pane(accounts[2].id.uuidString), at: chip.center)
        try await Task.sleep(for: HerdrDragCoordinator.springDelay + .milliseconds(180))
        #expect(model.selectedTabID == first.id)
        await page.settle()
        let canvas = try page.frame(HerdrDropGeometry.canvasKey)
        page.drag.update(.pane(accounts[2].id.uuidString), at: canvas.center)
        let collapsed = try #require(page.drag.snapBar)
        page.drag.update(.pane(accounts[2].id.uuidString), at: collapsed.frame.center)
        let expanded = try #require(page.drag.snapBar)
        #expect(expanded.expanded)
        let thumbnail = try #require(expanded.thumbnails.first)
        let slot = try #require(thumbnail.slots.last)
        page.drag.update(.pane(accounts[2].id.uuidString), at: slot.center)
        #expect(page.drag.target == .slot(thumbnail.template, thumbnail.slots.count - 1))
        try await page.capture("snap-layout-preview")
        page.drag.finish(.pane(accounts[2].id.uuidString), at: slot.center)
        #expect(model.currentTab?.layout.paneCount == 2)
        let before = model.tabs
        page.drag.update(.pane(accounts[4].id.uuidString), at: canvas.center)
        page.drag.cancel()
        page.drag.finish(.pane(accounts[4].id.uuidString), at: canvas.center)
        #expect(model.tabs == before)
        #expect(page.drag.item == nil)
    }

    @Test func replacementKeepsDisplacedAccountAndGroupedTabsKeepTheirShape() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let accounts = model.catalog.accounts
        model.open(accounts[0])
        let target = try #require(model.currentTab)
        model.drop(.pane(accounts[1].id.uuidString), on: .center(accounts[0].id.uuidString))
        #expect(model.currentTab?.id == target.id)
        #expect(model.currentTab?.focused == accounts[1].id.uuidString)
        #expect(model.tabs.count == 2)
        #expect(model.tabs.contains { $0.focused == accounts[0].id.uuidString })
        model.open(accounts[2])
        model.open(accounts[3], beside: true, side: .bottom)
        let grouped = try #require(model.currentTab)
        model.select(target)
        model.drop(.tab(grouped.id.uuidString), on: .outerEdge(.right))
        #expect(model.currentTab?.layout.paneCount == 3)
        let frames = try #require(
            model.currentTab?.layout.frames(
                in: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 6))
        let upper = try #require(frames[accounts[2].id.uuidString])
        let lower = try #require(frames[accounts[3].id.uuidString])
        #expect(upper.minX == lower.minX)
        #expect(upper.maxY < lower.minY)
        model.drop(.tab(target.id.uuidString), on: .tabBar(0))
        #expect(model.tabs.first?.id == target.id)
        model.separate(target.id.uuidString)
        #expect(model.tabs.allSatisfy { $0.layout.paneCount == 1 })
        #expect(model.tabs.flatMap { $0.layout.panes }.count == 4)
    }
}

@MainActor
private final class RenderedSocialWorkspace {
    let fixture: SocialManagerFixture
    let drag = HerdrDragCoordinator()
    let host: NSHostingView<AnyView>
    let window: NSWindow
    var model: SocialManagerModel { fixture.model }

    init() async throws {
        fixture = try SocialManagerFixture()
        fixture.model.profileID = fixture.model.catalog.profiles.first?.id
        host = NSHostingView(
            rootView: AnyView(
                SocialManagerPage(model: fixture.model, drag: drag)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.loadingAnimationsEnabled, false)
                    .environment(\.colorScheme, .light)))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1360, height: 900)
        window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        await settle()
    }

    func frame(_ key: String) throws -> CGRect { try #require(drag.frames[key]) }

    func settle() async {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func capture(_ name: String) async throws {
        await settle()
        guard let path = ProcessInfo.processInfo.environment["EDITH_SOCIAL_MANAGER_EVIDENCE_DIR"]
        else { return }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: folder.appendingPathComponent(name + ".png"))
    }

    func close() {
        drag.cancel()
        window.orderOut(nil)
        window.contentView = nil
        fixture.remove()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
