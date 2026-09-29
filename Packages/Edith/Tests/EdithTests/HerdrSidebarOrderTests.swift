import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
struct HerdrSidebarOrderTests {
    @Test func selectionFocusAndRefreshNeverReorderTheSidebar() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = fixture.store
        let agents = fixture.agents
        let spaces = store.agentSpaces.map(\.id)
        store.open(agents[2])
        store.open(agents[0], beside: .right)
        store.focus(agents[2].id)
        store.open(agents[1])
        store.selectBoard()
        store.apply([.local(herdrPresent: true, agents: agents.reversed())])
        #expect(store.listedAgents.map(\.id) == agents.map(\.id))
        #expect(store.agentSpaces.map(\.id) == spaces)
        store.closeAll()
    }

    @Test func manualOrderSurvivesFiltersMissingSessionsAndRestart() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = fixture.store
        let agents = fixture.agents
        store.moveSidebarAgent(agents[2].id, relativeTo: agents[0].id, after: false)
        store.moveSidebarSpace("local|beta", relativeTo: "local|alpha", after: false)
        store.kindFilter = ["Shell"]
        #expect(store.listedAgents.map(\.id) == [agents[2].id, agents[0].id, agents[1].id])
        store.machineFilter = "offline"
        #expect(store.listedAgents.isEmpty)
        store.machineFilter = "all"
        store.apply([.local(herdrPresent: true, agents: [agents[1]])])
        store.apply([.local(herdrPresent: true, agents: agents)])
        let restored = HerdrStore(
            defaults: fixture.defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        restored.apply([.local(herdrPresent: true, agents: agents)])
        #expect(restored.listedAgents.map(\.id) == [agents[2].id, agents[0].id, agents[1].id])
        #expect(restored.agentSpaces.map(\.title) == ["beta", "alpha"])
        restored.moveSidebarAgent(agents[2].id, relativeTo: agents[1].id, after: true)
        #expect(restored.listedAgents.map(\.id) == agents.map(\.id))
    }

    @Test func newSessionsAppendWithoutMovingExistingRows() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = fixture.store
        let added = Self.agent(4, space: "aardvark")
        store.apply([.local(herdrPresent: true, agents: [added] + fixture.agents.reversed())])
        #expect(store.listedAgents.map(\.id) == fixture.agents.map(\.id) + [added.id])
        #expect(store.agentSpaces.map(\.title) == ["alpha", "beta", "aardvark"])
    }

    private static func agent(_ index: Int, space: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "demo", pane: "w1:p\(index)", kind: "Shell", status: .idle,
            title: "Task \(index)", workspace: space, cwd: "/demo")
    }

    @MainActor
    private struct Fixture {
        let suite = "HerdrSidebarOrderTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: HerdrStore
        let agents: [HerdrAgent]

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
            agents = [agent(1, space: "alpha"), agent(2, space: "beta"), agent(3, space: "alpha")]
            store.apply([.local(herdrPresent: true, agents: agents)])
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
