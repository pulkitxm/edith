import AppKit
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite(.serialized) @MainActor struct TerminalWindowLifecycleTests {
    @Test func explicitWindowCloseStopsOnlyItsTerminalAndHidingPreservesIt() async throws {
        let first = try await makeTerminal()
        defer { first.model.stopAll(); first.window.close(); first.session.stop() }
        let second = try await makeTerminal()
        defer { second.model.stopAll(); second.window.close(); second.session.stop() }
        first.window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(first.holder.started)
        #expect(second.holder.started)
        first.window.close()
        #expect(await eventually { !first.holder.started })
        #expect(first.model.tabs.isEmpty)
        #expect(second.holder.started)
        second.model.closeTab(try #require(second.model.tabs.first?.id))
        #expect(await eventually { !second.holder.started })
        #expect(second.model.tabs.isEmpty)
    }

    private func makeTerminal() async throws -> Fixture {
        let session = MachineSession(
            machine: Machine(name: "terminal-fixture-\(UUID().uuidString)", host: "localhost"),
            local: true, observesWakeRequests: false)
        let model = TerminalTabsModel()
        let holder = model.addTab(named: "Synthetic child").holder
        holder.start(
            executable: "/bin/cat", arguments: [],
            environment: ["PATH=/usr/bin:/bin", "HOME=\(NSTemporaryDirectory())"],
            currentDirectory: NSTemporaryDirectory())
        var completed = false
        defer { if !completed { model.stopAll(); session.stop() } }
        #expect(holder.started)
        TerminalWindow.open(session: session, model: model)
        let window = try #require(
            NSApplication.shared.windows.first {
                $0.title == "Terminal · \(session.machine.name)"
            })
        completed = true
        return Fixture(session: session, model: model, window: window, holder: holder)
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private struct Fixture {
        let session: MachineSession
        let model: TerminalTabsModel
        let window: NSWindow
        let holder: TerminalSessionHolder
    }
}
