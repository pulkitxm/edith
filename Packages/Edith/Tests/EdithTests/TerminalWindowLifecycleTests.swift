import AppKit
import Darwin
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite(.serialized) @MainActor struct TerminalWindowLifecycleTests {
    @Test func explicitWindowCloseStopsOnlyItsTerminalAndHidingPreservesIt() async throws {
        let key = AppStorageKeys.Herdr.ghosttyTerminal
        let previous = SharedDefaults.store.object(forKey: key)
        SharedDefaults.store.set(false, forKey: key)
        defer {
            if let previous {
                SharedDefaults.store.set(previous, forKey: key)
            } else {
                SharedDefaults.store.removeObject(forKey: key)
            }
        }
        let first = try await makeTerminal()
        defer { first.model.stopAll(); first.window.close(); first.session.stop() }
        let second = try await makeTerminal()
        defer { second.model.stopAll(); second.window.close(); second.session.stop() }
        first.window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(isRunning(first.pid))
        #expect(isRunning(second.pid))
        first.window.close()
        #expect(await eventually { !isRunning(first.pid) })
        #expect(first.model.tabs.isEmpty)
        #expect(isRunning(second.pid))
        second.model.closeTab(try #require(second.model.tabs.first?.id))
        #expect(await eventually { !isRunning(second.pid) })
        #expect(second.model.tabs.isEmpty)
        first.model.stopAll()
        #expect(await eventually { !isRunning(first.pid) })
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
        let pid = holder.terminalView.process.shellPid
        var completed = false
        defer { if !completed { model.stopAll(); session.stop() } }
        #expect(pid > 0)
        #expect(isRunning(pid))
        TerminalWindow.open(session: session, model: model)
        let window = try #require(
            NSApplication.shared.windows.first {
                $0.title == "Terminal · \(session.machine.name)"
            })
        completed = true
        return Fixture(session: session, model: model, window: window, pid: pid)
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        return kill(pid, 0) == 0
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
        let pid: pid_t
    }
}
