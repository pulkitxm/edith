import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct HerdrLayoutEvidenceTests {
    nonisolated private static let evidenceKey = "EDITH_HERDR_LAYOUT_EVIDENCE_DIR"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[evidenceKey] != nil))
    func sideBySideTabsRenderTheActualPageWithSyntheticAgents() throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        #expect(dataRoot.hasPrefix(runtime + "/"))
        guard dataRoot.hasPrefix(runtime + "/") else { return }
        let output = URL(
            fileURLWithPath: try #require(environment[Self.evidenceKey]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let suite = "HerdrLayoutEvidenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HerdrStore(
            defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        let agents = Self.agents
        store.apply([.local(herdrPresent: true, agents: agents)])
        store.open(agents[0])
        store.open(agents[1], beside: .right)
        store.open(agents[2], beside: .bottom)
        store.open(agents[3], beside: .bottom)
        store.focus(agents[0].id)
        let tabID = try #require(store.currentTab).id
        store.arrange(tabID, as: .grid)
        store.open(agents[4])
        store.selectedTab = tabID
        for (index, session) in store.sessions.enumerated() {
            session.holder.start(
                executable: "/bin/sh", arguments: ["-c", Self.script(index)],
                environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8"])
        }
        defer { store.closeAll() }

        try render(HerdrPage(store: store), size: NSSize(width: 1440, height: 900))
            .write(to: output.appendingPathComponent("herdr-grid.png"), options: .atomic)

        store.arrange(tabID, as: .focusLeft)
        try render(HerdrPage(store: store), size: NSSize(width: 1440, height: 900))
            .write(to: output.appendingPathComponent("herdr-focus-left.png"), options: .atomic)

        let tab = try #require(store.currentTab)
        guard case let .split(split) = tab.layout else { return }
        store.resize(tabID, split: split.id, index: 0, by: -0.2)
        store.saveArrangement(of: tabID, named: "Review")
        store.arrange(tabID, as: .grid)
        try render(
            HerdrLayoutPopover(store: store, tab: tab, hideAgents: false)
                .background(DashSkin.paper(true)),
            size: NSSize(width: 380, height: 420)
        )
        .write(to: output.appendingPathComponent("herdr-layout-popover.png"), options: .atomic)

        try dragEvidence(store: store, tabID: tabID, output: output)
    }

    private func dragEvidence(store: HerdrStore, tabID: String, output: URL) throws {
        let pairTab = try #require(store.tab(containing: Self.agents[4].id)).id
        store.selectedTab = tabID
        store.separate(tabID)
        store.selectedTab = try #require(store.tab(containing: Self.agents[0].id)).id
        store.open(Self.agents[1], beside: .right)
        let pair = try #require(store.currentTab).id
        let drag = HerdrDragCoordinator()
        let size = NSSize(width: 1440, height: 900)
        let frames = try renderFrames(HerdrPage(store: store, drag: drag), size: size, drag: drag)
        let canvas = try #require(frames[HerdrDropGeometry.canvasKey])
        let right = try #require(
            store.tab(pair)?.layout.paneFrames(in: canvas, gap: UIScale.pt(6))[Self.agents[1].id])

        drag.update(.agent(Self.agents[2]), at: CGPoint(x: right.midX, y: right.midY))
        drag.update(.agent(Self.agents[2]), at: CGPoint(x: right.midX, y: right.maxY - 40))
        #expect(drag.target == .edge(Self.agents[1].id, .bottom))
        try render(HerdrPage(store: store, drag: drag), size: size)
            .write(to: output.appendingPathComponent("herdr-drag-split.png"), options: .atomic)

        drag.update(.agent(Self.agents[2]), at: CGPoint(x: canvas.midX, y: canvas.minY + 40))
        let bar = try #require(drag.snapBar)
        #expect(bar.expanded)
        let thumbnail = try #require(bar.thumbnails.first { $0.template == .builtIn(.focusLeft) })
        let slot = thumbnail.slots[0]
        drag.update(.agent(Self.agents[2]), at: CGPoint(x: slot.midX, y: slot.midY))
        #expect(drag.target == .slot(.builtIn(.focusLeft), 0))
        try render(HerdrPage(store: store, drag: drag), size: size)
            .write(to: output.appendingPathComponent("herdr-drag-layouts.png"), options: .atomic)

        let chip = try #require(frames[HerdrDropGeometry.chipPrefix + pairTab])
        drag.update(.agent(Self.agents[2]), at: CGPoint(x: chip.minX + 4, y: chip.midY))
        try render(HerdrPage(store: store, drag: drag), size: size)
            .write(to: output.appendingPathComponent("herdr-drag-tab.png"), options: .atomic)
        drag.cancel()
    }

    private func renderFrames(_ page: HerdrPage, size: NSSize, drag: HerdrDragCoordinator)
        throws -> [String: CGRect]
    {
        _ = try render(page, size: size)
        return drag.frames
    }

    private func render<Content: View>(_ content: Content, size: NSSize) throws -> Data {
        let host = NSHostingView(
            rootView:
                content
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.machineConnectionsEnabled, false)
                .environment(\.terminalLaunchEnabled, false)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil }
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<4 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            redraw(host)
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-evidence-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0, let data = try? Data(contentsOf: file), !data.isEmpty {
            return data
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func redraw(_ view: NSView) {
        for child in view.subviews { redraw(child) }
        view.needsDisplay = true
        view.displayIfNeeded()
    }

    private static let agents: [HerdrAgent] = [
        ("Claude Code", "Refactor the router", HerdrAgentStatus.working),
        ("Codex", "Write billing tests", .blocked),
        ("OpenCode", "Tidy the docs", .done),
        ("Claude Code", "Polish the settings UI", .idle),
        ("Codex", "Bump dependencies", .idle),
    ].enumerated().map { index, entry in
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "demo", pane: "w1:p\(index + 1)", kind: entry.0, status: entry.2,
            title: entry.1, workspace: "demo", cwd: "/tmp/demo")
    }

    private static func script(_ index: Int) -> String {
        let steps = [
            ["read src/router.ts", "edit src/router.ts (+42 -17)", "run swift test"],
            ["read Tests/BillingTests.swift", "waiting for approval: run make test"],
            ["edit docs/getting-started.md", "edit docs/cli.md", "all docs updated"],
            ["read Settings/Appearance.swift", "idle, waiting for input"],
            ["read Package.resolved", "idle, waiting for input"],
        ][index % 5]
        let lines = steps.map { "printf '  \\033[32m✓\\033[0m \($0)\\n'" }.joined(separator: "; ")
        return
            "printf '\\033[1;36m● mock agent \(index + 1)\\033[0m  synthetic session\\n\\n'; \(lines); printf '\\n\\033[2m> \\033[0m'; sleep 60"
    }
}
