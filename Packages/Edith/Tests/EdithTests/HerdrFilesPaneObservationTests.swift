import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithAgent
@testable import EdithKit

@MainActor
@Suite(.serialized) struct HerdrFilesPaneObservationTests {
    init() {
        _ = TestWindowHost.application
    }

    @Test func aRemoteAgentsFilesPaneObservesItsMachineWhileShown() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let listener = MachineMetricsTestListener(runtime: runtime)
        defer { listener.stop() }
        let machine = Machine(name: "remote-box", host: "remote.invalid", username: "dev")
        let session = MachineSession(
            machine: machine, local: false, observesWakeRequests: false,
            metricsClient: listener.client())
        let agent = HerdrAgent.make(
            machineID: machine.id.uuidString, machineName: machine.name, machineIsLocal: false,
            sshTarget: "dev@remote.invalid", session: "default", pane: "a", kind: "claude",
            status: .idle, title: "Remote agent", workspace: "", cwd: "/srv/app")
        let suite = "HerdrFilesPaneObservation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tab = HerdrOpenTab(
            agent: agent, machine: machine, view: .files, holder: TerminalSessionHolder(),
            quinjet: HerdrQuinjetSession(),
            files: HerdrFilesSession { _ in session },
            split: HerdrSplitCompanionState(agentID: agent.id, defaults: defaults))
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in })
        #expect(!session.isCollecting)

        let window = ShownTestWindow.make()
        let hosting = NSHostingView(
            rootView: HerdrSessionView(
                store: store, tab: tab, launchEnabled: false, showsDetails: false))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = hosting
        try await eventually { tab.files.finder?.session === session && session.isCollecting }
        #expect(tab.files.finder?.path == "/srv/app")

        window.contentView = nil
        try await eventually { !session.isCollecting }
    }

    @Test func splitShowsTheRemoteFilesBesideTheAgent() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let listener = MachineMetricsTestListener(runtime: runtime)
        defer { listener.stop() }
        let machine = Machine(name: "remote-box", host: "remote.invalid", username: "dev")
        let session = MachineSession(
            machine: machine, local: false, observesWakeRequests: false,
            metricsClient: listener.client())
        let agent = HerdrAgent.make(
            machineID: machine.id.uuidString, machineName: machine.name, machineIsLocal: false,
            sshTarget: "dev@remote.invalid", session: "default", pane: "a", kind: "claude",
            status: .idle, title: "Remote agent", workspace: "", cwd: "/srv/app")
        let suite = "HerdrFilesPaneObservation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = HerdrSplitCompanionState(agentID: agent.id, defaults: defaults)
        let tab = HerdrOpenTab(
            agent: agent, machine: machine, view: .split, holder: TerminalSessionHolder(),
            quinjet: HerdrQuinjetSession(), files: HerdrFilesSession { _ in session },
            split: split)
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in })
        let window = ShownTestWindow.make()
        let hosting = NSHostingView(
            rootView: HerdrSessionView(
                store: store, tab: tab, launchEnabled: false, showsDetails: false))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = hosting
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.files.finder == nil)
        #expect(!session.isCollecting)

        split.select(.files)
        try await eventually { tab.files.finder?.session === session && session.isCollecting }
        #expect(tab.showsFiles)
        #expect(!tab.showsDiff)

        split.select(.diff)
        try await eventually { !session.isCollecting }
        window.contentView = nil
    }

    @Test func aSeparateFinderWindowObservesItsMachine() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let listener = MachineMetricsTestListener(runtime: runtime)
        defer { listener.stop() }
        let session = MachineSession(
            machine: Machine(name: "remote-box", host: "remote.invalid", username: "dev"),
            local: false, observesWakeRequests: false, metricsClient: listener.client())
        let window = ShownTestWindow.make()
        let hosting = NSHostingView(rootView: FinderWindowView(session: session, path: "/srv"))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = hosting
        try await eventually { session.isCollecting }
        window.contentView = nil
        try await eventually { !session.isCollecting }
    }

    @Test func aHiddenWindowDoesNotKeepTheMachineObserved() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let listener = MachineMetricsTestListener(runtime: runtime)
        defer { listener.stop() }
        let session = MachineSession(
            machine: Machine(name: "remote-box", host: "remote.invalid", username: "dev"),
            local: false, observesWakeRequests: false, metricsClient: listener.client())
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600))
        let hosting = NSHostingView(rootView: FinderWindowView(session: session, path: "/srv"))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = hosting
        try await eventually { !session.isCollecting }
        window.contentView = nil
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(condition())
    }
}

private final class ShownTestWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }

    static func make() -> ShownTestWindow {
        _ = TestWindowHost.application
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = ShownTestWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(NSPoint(x: minX - 4_000, y: minY - 4_000))
        return window
    }
}
