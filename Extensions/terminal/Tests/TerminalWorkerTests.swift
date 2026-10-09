import EdithExtensionSupport
import Foundation
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalWorkerTests {
    @Test func disabledWorkerOwnsAndReleasesAllTabsAndEngineExactlyOnce() async throws {
        var engineStops = 0
        let worker = TerminalWorker(shutdownEngine: { engineStops += 1 })
        let tab = try #require(worker.openTab())
        tab.holder.start(
            .init(
                executable: "/bin/cat", arguments: [], environment: [], currentDirectory: "/tmp",
                startupCommand: nil))
        tab.holder.sendInput("synthetic input")
        #expect(worker.status.running == 1 && tab.holder.hasQueuedInput)
        worker.shutdown(); worker.shutdown()
        #expect(engineStops == 1 && worker.model.tabs.isEmpty && !tab.holder.started)
        #expect(!tab.holder.hasQueuedInput && tab.holder.ghosttyLaunch == nil)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("terminal.open", payload: Data())
        }
    }

    @Test func commandsRejectMalformedOversizedUnknownAndCancelledRequests() async throws {
        let worker = TerminalWorker(shutdownEngine: {})
        defer { worker.shutdown() }
        for (command, payload) in [
            ("terminal.unknown", Data()), ("terminal.open", Data(repeating: 0, count: 8193)),
            ("terminal.select", Data("invalid".utf8)), ("terminal.status", Data("true".utf8)),
            ("terminal.broadcast", Data(#"{"command":" "}"#.utf8)),
        ] {
            await #expect(throws: (any Error).self) {
                try await worker.execute(command, payload: payload)
            }
        }
        let cancelled = Task {
            try? await Task.sleep(for: .milliseconds(10));
            return try await worker.execute("terminal.open", payload: Data())
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(worker.model.tabs.isEmpty)
    }

    @Test func tabLimitBoundsOpenCommandsAndClosingAlwaysStopsTheHolder() throws {
        let model = TerminalTabsModel(requestUserClose: { _, finish in finish(true) })
        let worker = TerminalWorker(model: model, shutdownEngine: {})
        defer { worker.shutdown() }
        for _ in 0..<TerminalTabsModel.maximumTabs { #expect(worker.openTab() != nil) }
        #expect(worker.openTab() == nil && worker.status.sessions == 32)
        let tab = try #require(model.tabs.first)
        tab.holder.start(
            .init(
                executable: "/bin/cat", arguments: [], environment: [], currentDirectory: "/tmp",
                startupCommand: nil))
        model.closeTab(tab.id)
        #expect(!tab.holder.started && model.tabs.count == 31)
        #expect(worker.openTab() != nil)
    }

    @Test func broadcastReportsOnlyRunningRecipientsAndRejectsNullInput() throws {
        let model = TerminalTabsModel()
        defer { model.stopAll() }
        let first = try #require(model.addTab()); _ = model.addTab()
        first.holder.start(
            .init(
                executable: "/bin/cat", arguments: [], environment: [], currentDirectory: "/tmp",
                startupCommand: nil))
        let plan = try #require(try? TerminalBroadcastPlan.make(command: " true ").get())
        var inputs: [String] = []
        let delivery = model.sendBroadcast(plan, send: { _, input in inputs.append(input) })
        #expect(delivery.sent == 1 && delivery.unavailable == 1 && inputs == ["true\n"])
        #expect(TerminalBroadcastPlan.make(command: "bad\u{0}") == .failure(.invalidCommand))
    }
}
