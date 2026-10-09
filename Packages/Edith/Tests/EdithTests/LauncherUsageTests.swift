import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct LauncherUsageTests {
    @Test func usageSurvivesReloadAndKeepsUnseenItemsStable() throws {
        let suite = "LauncherUsageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = LauncherUsage(defaults: defaults)
        usage.record([["kind", "older"]], at: Date(timeIntervalSince1970: 100))
        usage.record([["kind", "newer"]], at: Date(timeIntervalSince1970: 200))
        let reloaded = LauncherUsage(defaults: defaults)
        #expect(
            reloaded.ordered(["unseen-b", "older", "unseen-a", "newer"]) { ["kind", $0] }
                == ["newer", "older", "unseen-b", "unseen-a"])
        #expect(
            reloaded.ordered(["older", "newer"].filter { $0.contains("er") }) { ["kind", $0] }
                == ["newer", "older"])
    }

    @Test func openingAndRefocusingRecordsUsageWithoutReorderingTheSidebar() throws {
        let suite = "LauncherUsageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        let first = agent(machine: "local", pane: "p1", kind: "Terminal", space: "Alpha")
        let second = agent(machine: "remote", pane: "p2", kind: "Shell", space: "Zeta")
        store.apply([
            .local(herdrPresent: true, agents: [first]),
            HerdrHostSnapshot(
                id: "remote", name: "Remote", isLocal: false, herdrPresent: true,
                reachable: true, agents: [second]),
        ])
        store.open(first)
        store.open(second, beside: .right)
        #expect(store.listedAgents.map(\.id) == [first.id, second.id])
        #expect(store.recentHosts.map(\.id) == ["remote", "local"])
        #expect(store.agentSpaces.map(\.title) == ["Alpha", "Zeta"])
        #expect(
            store.usage.lastUsed(["agent", second.id]) > store.usage.lastUsed(["agent", first.id]))
        #expect(store.usage.lastUsed(["space", "local", "Zeta"]) == .distantPast)
        store.focus(first.id)
        #expect(store.listedAgents.map(\.id) == [first.id, second.id])
        #expect(store.agentSpaces.map(\.title) == ["Alpha", "Zeta"])
        #expect(store.recentHosts.map(\.id) == ["local", "remote"])
        #expect(
            store.usage.lastUsed(["kind", "Terminal"]) > store.usage.lastUsed(["kind", "Shell"]))
        store.closeAll()
    }

    @Test func failedLaunchDoesNotRecordUsage() async throws {
        let suite = "LauncherUsageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HerdrStore(
            defaults: defaults, liveWatcher: { _ in },
            newAgentPaneCreator: { _, _, _, _ in throw CocoaError(.fileNoSuchFile) },
            machinesProvider: { [] })
        do {
            try await store.launchNewAgent(
                kind: "Terminal", host: .local(herdrPresent: true), existingSpace: nil,
                newSpaceLabel: "Demo")
            Issue.record("Expected launch failure")
        } catch {
            #expect(store.usage.lastUsed(["kind", "Terminal"]) == .distantPast)
            #expect(store.usage.lastUsed(["machine", "local"]) == .distantPast)
        }
    }

    @Test func searchRepliesPreserveLastUsedOrdering() async throws {
        let suite = "LauncherUsageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = LauncherUsage(defaults: defaults)
        let older = agent(machine: "local", pane: "older", kind: "Terminal", space: "Demo")
        let newer = agent(machine: "local", pane: "newer", kind: "Terminal", space: "Demo")
        usage.record(older, at: Date(timeIntervalSince1970: 100))
        usage.record(newer, at: Date(timeIntervalSince1970: 200))
        let model = HerdrSearchModel(
            searcher: { _ in
                AgentSearchReply(
                    machineID: "local",
                    hits: [older, newer].map { HerdrSearchModelTests.hit($0, "demo") })
            }, decider: { nil }, usage: usage)
        model.search(agents: [older, newer], hosts: [.local(herdrPresent: true)])
        #expect(model.rows.map(\.id) == [newer.id, older.id])
        for _ in 0..<100 where model.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isBusy)
        #expect(model.rows.map(\.id) == [newer.id, older.id])
        #expect(model.selectedRow?.id == newer.id)
        model.move(1)
        #expect(model.selectedRow?.id == older.id)
        model.cancel()
    }

    private func agent(machine: String, pane: String, kind: String, space: String) -> HerdrAgent {
        .make(
            machineID: machine, machineName: machine, machineIsLocal: machine == "local",
            sshTarget: nil, session: "demo", pane: pane, kind: kind, status: .idle,
            title: pane, workspace: space, cwd: "/demo")
    }
}
