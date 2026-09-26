import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct HerdrMessagingEvidenceTests {
    nonisolated private static let evidenceKey = "EDITH_HERDR_MESSAGE_EVIDENCE_DIR"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[evidenceKey] != nil))
    func messagesAndFinishedHooksRenderOnTheActualPage() throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        #expect(dataRoot.hasPrefix(runtime + "/"))
        guard dataRoot.hasPrefix(runtime + "/") else { return }
        let output = URL(
            fileURLWithPath: try #require(environment[Self.evidenceKey]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let suite = "HerdrMessagingEvidenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let messaging = HerdrMessaging(
            broadcaster: { _, _ in [:] }, arm: { _, _, _ in HerdrHooksSnapshot() },
            remove: { _ in HerdrHooksSnapshot() })
        let store = HerdrStore(
            defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] },
            messaging: messaging)
        let agents = Self.agents
        store.apply([.local(herdrPresent: true, agents: agents)])
        var finished = Self.hook(agents[2], "Open a PR for the docs.")
        finished.settle(.sent, "Submitted", at: Date().addingTimeInterval(-240))
        messaging.adopt(
            HerdrHooksSnapshot(hooks: [
                Self.hook(agents[0], "Now run the full test suite and fix anything that fails."),
                finished,
            ]))
        store.open(agents[0])
        defer { store.closeAll() }

        try render(HerdrPage(store: store), size: NSSize(width: 1440, height: 900))
            .write(to: output.appendingPathComponent("herdr-message-armed.png"), options: .atomic)

        store.focus(agents[0].id)
        store.close(agents[0].id)
        store.open(agents[2])
        try render(HerdrPage(store: store), size: NSSize(width: 1440, height: 900))
            .write(to: output.appendingPathComponent("herdr-message-sent.png"), options: .atomic)

        messaging.compose(.stopped, from: store.filteredAgents)
        let draft = try #require(messaging.draft)
        try render(
            HerdrMessageSheet(messaging: messaging, draft: draft),
            size: NSSize(width: 460, height: 300)
        )
        .write(to: output.appendingPathComponent("herdr-message-stopped.png"), options: .atomic)

        messaging.compose(to: agents[3], delivery: .whenFinished)
        let single = try #require(messaging.draft)
        try render(
            HerdrMessageSheet(messaging: messaging, draft: single),
            size: NSSize(width: 460, height: 420)
        )
        .write(
            to: output.appendingPathComponent("herdr-message-when-finished.png"), options: .atomic)

        messaging.compose(to: agents[3], delivery: .after)
        let after = try #require(messaging.draft)
        try render(
            HerdrMessageSheet(messaging: messaging, draft: after),
            size: NSSize(width: 460, height: 520)
        )
        .write(to: output.appendingPathComponent("herdr-message-after.png"), options: .atomic)

        messaging.compose(to: agents[3], delivery: .at)
        let timed = try #require(messaging.draft)
        try render(
            HerdrMessageSheet(messaging: messaging, draft: timed),
            size: NSSize(width: 460, height: 520)
        )
        .write(to: output.appendingPathComponent("herdr-message-at.png"), options: .atomic)
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
        ("Codex", "Bump dependencies", .working),
    ].enumerated().map { index, entry in
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "demo", pane: "w1:p\(index + 1)", kind: entry.0, status: entry.2,
            title: entry.1, workspace: "demo", cwd: "/tmp/demo", stateSequence: 3)
    }

    private static func hook(_ agent: HerdrAgent, _ message: String) -> HerdrAgentHook {
        HerdrAgentHook(
            agent: agent, message: message,
            observation: HerdrAgentObservation(
                kind: agent.kind, status: agent.status, sequence: agent.stateSequence,
                identity: HerdrAgentIdentity(terminalID: "term_1", processGroupID: 123)),
            schedule: .whenFinished)
    }
}
