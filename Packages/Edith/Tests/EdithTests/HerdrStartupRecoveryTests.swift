import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct HerdrStartupRecoveryTests {
    @Test(arguments: [HerdrAgentStatus.idle, .working, .done], ["timeout", "agent_not_ready"])
    func confirmationAfterFailureClearsTheWarning(status: HerdrAgentStatus, code: String)
        async throws
    {
        let store = makeStore(code: code)
        defer { store.closeAll() }
        let id = try await launch(in: store)
        await store.agentStartupTasks[id]?.value
        #expect(store.agentStartupMessages[id] != nil)

        store.apply([.local(herdrPresent: true, agents: [agent(status: status)])])

        #expect(store.agentStartupMessages[id] == nil)
        #expect(store.focusedSession?.id == id)
    }

    @Test(arguments: [HerdrAgentStatus.idle, .working, .done])
    func confirmationBeforeTheTimeoutResponsePreventsAStaleWarning(status: HerdrAgentStatus)
        async throws
    {
        let (response, continuation) = AsyncStream<Void>.makeStream()
        let store = makeStore(response: response)
        defer { store.closeAll() }
        let id = try await launch(in: store)
        store.apply([.local(herdrPresent: true, agents: [agent(status: status)])])
        continuation.yield(())
        continuation.finish()

        await store.agentStartupTasks[id]?.value

        #expect(store.agentStartupMessages[id] == nil)
        #expect(store.focusedSession?.id == id)
    }

    @Test(arguments: [HerdrAgentStatus.blocked, .unknown])
    func unconfirmedStatesKeepTheWarning(status: HerdrAgentStatus) async throws {
        let store = makeStore()
        defer { store.closeAll() }
        let id = try await launch(in: store)
        await store.agentStartupTasks[id]?.value

        store.apply([.local(herdrPresent: true, agents: [agent(status: status)])])

        #expect(store.agentStartupMessages[id] != nil)
    }

    @Test func unrelatedOrUnavailableAgentsDoNotConfirmStartup() async throws {
        let store = makeStore()
        defer { store.closeAll() }
        let id = try await launch(in: store)
        await store.agentStartupTasks[id]?.value
        var candidate = agent(status: .idle)
        candidate.kind = "OpenCode"
        store.apply([.local(herdrPresent: true, agents: [candidate])])
        #expect(store.agentStartupMessages[id] != nil)

        candidate = agent(status: .idle, pane: "w1:p3")
        store.apply([.local(herdrPresent: true, agents: [candidate])])
        #expect(store.agentStartupMessages[id] != nil)

        var host = HerdrHostSnapshot.local(herdrPresent: true, agents: [agent(status: .idle)])
        host.reachable = false
        store.apply([host])
        #expect(store.agentStartupMessages[id] != nil)
        host.reachable = true
        host.error = "Connection lost"
        store.apply([host])
        #expect(store.agentStartupMessages[id] != nil)
    }

    @Test func definitiveLaunchFailuresAreNotHiddenByAgentStatus() async throws {
        let store = makeStore(code: "agent_executable_not_found")
        defer { store.closeAll() }
        let id = try await launch(in: store)
        await store.agentStartupTasks[id]?.value

        store.apply([.local(herdrPresent: true, agents: [agent(status: .idle)])])

        #expect(store.agentStartupMessages[id] == "Startup detail")
    }

    private func makeStore(code: String = "timeout", response: AsyncStream<Void>? = nil)
        -> HerdrStore
    {
        HerdrStore(
            liveWatcher: { _ in },
            newAgentPaneCreator: { _, _, _, _, _ in
                HerdrCreatedPane(workspaceID: "w1", tabID: "w1:t2", paneID: "w1:p2")
            },
            agentStarter: { _, _, _ in
                if let response {
                    for await _ in response { break }
                }
                throw HerdrCommandError.commandFailed(
                    "{\"error\":{\"code\":\"\(code)\",\"message\":\"Startup detail\"}}")
            }, machinesProvider: { [] })
    }

    private func launch(in store: HerdrStore) async throws -> String {
        try await store.launchNewAgent(
            kind: "Codex", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: "Startup demo")
        return try #require(store.focusedSession?.id)
    }

    private func agent(status: HerdrAgentStatus, pane: String = "w1:p2") -> HerdrAgent {
        HerdrAgent.make(
            machineID: HerdrHostSnapshot.localID, machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "default", pane: pane, kind: "Codex", status: status,
            title: "Startup demo", workspace: "Startup demo", cwd: "/tmp")
    }
}
