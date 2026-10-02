import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct LauncherUsageEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDITH_LAUNCHER_EVIDENCE_DIR"] != nil))
    func tabLayoutChoicesRenderInTheActualPopup() throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        try #require(dataRoot.hasPrefix(runtime + "/"))
        let output = URL(fileURLWithPath: try #require(environment["EDITH_LAUNCHER_EVIDENCE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "LauncherLayoutEvidenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        store.tabs = [HerdrTab(agentID: "demo-1"), HerdrTab(agentID: "demo-2")]
        store.selectedTab = store.tabs[1].id
        store.newAgentPopupModel().layoutChoice = .sideBySide
        let reopened = store.newAgentPopupModel()
        store.selectedTab = store.tabs[0].id
        let otherTab = store.newAgentPopupModel()
        store.selectedTab = store.tabs[1].id
        let returned = store.newAgentPopupModel()
        #expect(reopened.layoutChoice == .sideBySide)
        #expect(otherTab.layoutChoice == .newTab)
        #expect(returned.layoutChoice == .sideBySide)
        let stages = [
            ("Tab 2: reopen Command-N", reopened),
            ("Switch to Tab 1", otherTab),
            ("Return to Tab 2", returned),
        ]
        try render(
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(stage.0).font(.system(size: 16, weight: .semibold))
                        Label(
                            stage.1.layoutChoice.title, systemImage: stage.1.layoutChoice.symbolName
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        HerdrNewAgentPopup(store: store, model: stage.1)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(20)
            .background(DashSkin.paper(true)),
            size: NSSize(width: UIScale.pt(1320) + 72, height: UIScale.pt(380) + 100)
        ).write(to: output.appendingPathComponent("launcher-tab-layouts.png"), options: .atomic)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDITH_LAUNCHER_EVIDENCE_DIR"] != nil))
    func recentItemsRenderInTheActualPickers() throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        try #require(dataRoot.hasPrefix(runtime + "/"))
        let output = URL(fileURLWithPath: try #require(environment["EDITH_LAUNCHER_EVIDENCE_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "LauncherUsageEvidenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        let local = HerdrHostSnapshot.local(herdrPresent: true)
        let remote = HerdrHostSnapshot(
            id: "demo-remote", name: "Demo workstation", isLocal: false,
            herdrPresent: true, reachable: true)
        store.apply([local, remote])
        let kinds = HerdrKind.filterLabels
        let recentKind = try #require(kinds.last)
        store.usage.record(
            [["kind", kinds[0]], ["machine", "local"], ["space", remote.id, "Alpha sandbox"]],
            at: Date(timeIntervalSince1970: 100))
        store.usage.record(
            [["kind", recentKind], ["machine", remote.id], ["space", remote.id, "Zeta review"]],
            at: Date(timeIntervalSince1970: 200))
        let machine = HerdrNewAgentPopupModel()
        machine.selectKind(recentKind)
        let space = HerdrNewAgentPopupModel()
        space.selectKind(recentKind)
        space.selectMachine(remote)
        space.workspaces = [
            HerdrWorkspaceSummary(id: "w1", label: "Alpha sandbox", tabCount: 1, paneCount: 1),
            HerdrWorkspaceSummary(id: "w2", label: "Unused workspace", tabCount: 1, paneCount: 1),
            HerdrWorkspaceSummary(id: "w3", label: "Zeta review", tabCount: 2, paneCount: 2),
        ]
        try render(
            HStack(spacing: 16) {
                HerdrNewAgentPopup(store: store)
                HerdrNewAgentPopup(store: store, model: machine)
                HerdrNewAgentPopup(store: store, model: space)
            }
            .padding(16)
            .background(DashSkin.paper(true)),
            size: NSSize(width: UIScale.pt(1320) + 64, height: UIScale.pt(380) + 32)
        ).write(to: output.appendingPathComponent("launcher-recent.png"), options: .atomic)

        let model = QuinjetPageModel(usage: store.usage)
        let tab = try #require(model.selectedTab)
        let worktrees = ["main", "feature/older", "feature/recent"].map { branch in
            QuinjetWorktree(
                path: "/demo/\(branch)", head: "abc123", branch: branch, current: branch == "main",
                bare: false, detached: false, locked: nil, prunable: nil)
        }
        model.open(
            worktrees[1], projectName: "Demo project", available: worktrees,
            in: tab, launchEnabled: false)
        model.open(
            worktrees[2], projectName: "Demo project", available: worktrees,
            in: tab, launchEnabled: false)
        #expect(
            model.recentWorktrees(for: tab).map(\.branch) == [
                "feature/recent", "feature/older", "main",
            ])
        try render(
            QuinjetWorktreePicker(
                projectName: "Demo project", worktrees: model.recentWorktrees(for: tab),
                selectedPath: worktrees[2].path, select: { _ in }
            )
            .background(DashSkin.paper(true)),
            size: NSSize(width: UIScale.pt(420), height: UIScale.pt(250))
        ).write(to: output.appendingPathComponent("worktrees-recent.png"), options: .atomic)
    }

    private func render<Content: View>(_ content: Content, size: NSSize) throws -> Data {
        let host = NSHostingView(
            rootView:
                content
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.machineConnectionsEnabled, false)
                .environment(\.terminalLaunchEnabled, false)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil })
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
            .appendingPathComponent("launcher-evidence-\(UUID().uuidString).png")
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
}
