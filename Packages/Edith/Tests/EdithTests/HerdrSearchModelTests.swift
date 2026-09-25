import AppKit
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

private actor HerdrSearchGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class HerdrSearchCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AgentSearchRequest] = []

    var all: [AgentSearchRequest] { lock.withLock { requests } }

    func add(_ request: AgentSearchRequest) -> Int {
        lock.withLock {
            requests.append(request)
            return requests.filter { $0.machineID == request.machineID }.count
        }
    }
}

private struct HerdrSearchDecider: JevDeciding {
    let probabilities: [String: Double]

    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        #expect(purpose == AgentSearchJev.purpose)
        return JevRouterTests.decision(AgentSearchJev.question, probabilities)
    }
}

@MainActor
@Suite struct HerdrSearchModelTests {
    nonisolated static let remoteID = "7A3F0C2E-0000-4000-8000-000000000001"

    nonisolated static func agent(
        _ kind: String, pane: String, title: String, machineID: String = "local",
        cwd: String = "/work/atlas", category: HerdrPaneCategory = .agent
    ) -> HerdrAgent {
        HerdrAgent.make(
            machineID: machineID, machineName: machineID == "local" ? "This Mac" : "devbox",
            machineIsLocal: machineID == "local", sshTarget: nil, session: "default", pane: pane,
            kind: kind, status: .working, title: title, workspace: "atlas", cwd: cwd,
            category: category)
    }

    nonisolated static func hit(_ agent: HerdrAgent, _ snippet: String, score: Double = 1)
        -> AgentSearchHit
    {
        AgentSearchHit(
            id: agent.id, source: .transcript, sessionID: agent.pane, title: agent.title,
            snippet: snippet, summary: "asked about \(snippet)", lastActivity: 1_790_000_000,
            score: score)
    }

    nonisolated static let launch = agent("Claude Code", pane: "p1", title: "Speed up launch")
    nonisolated static let docs = agent("Claude Code", pane: "p2", title: "Onboarding docs")
    nonisolated static let shell = agent(
        "Terminal", pane: "t1", title: "zsh", category: .terminal)
    nonisolated static let remote = agent(
        "Codex", pane: "p9", title: "Billing export", machineID: remoteID)

    nonisolated static var hosts: [HerdrHostSnapshot] {
        [
            .local(herdrPresent: true, agents: [launch, docs, shell]),
            HerdrHostSnapshot(
                id: remoteID, name: "devbox", isLocal: false, herdrPresent: true,
                reachable: true, agents: [remote]),
            HerdrHostSnapshot(
                id: "7A3F0C2E-0000-4000-8000-000000000002", name: "buildbox", isLocal: false,
                herdrPresent: false, reachable: false),
        ]
    }

    nonisolated static let agents = [launch, docs, shell, remote]

    func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func listsOnlyOpenAgentsGroupedByMachine() {
        let model = HerdrSearchModel(
            searcher: { request in
                try await Task.sleep(for: .seconds(30))
                return AgentSearchReply(machineID: request.machineID)
            }, decider: { nil })
        model.search(agents: Self.agents, hosts: Self.hosts)
        #expect(model.sections.map(\.name) == ["This Mac", "devbox"])
        #expect(model.rows.map(\.id) == [Self.launch.id, Self.docs.id, Self.remote.id])
        model.cancel()
    }

    @Test func sendsEveryOpenAgentAsATargetOnItsOwnMachine() async {
        let calls = HerdrSearchCalls()
        let model = HerdrSearchModel(
            searcher: { request in
                _ = calls.add(request)
                return AgentSearchReply(machineID: request.machineID)
            }, decider: { nil })
        model.query = "launch"
        model.search(agents: Self.agents, hosts: Self.hosts)
        await eventually { model.machineProgress.done == 2 }
        let requests = calls.all.sorted { $0.machineID < $1.machineID }
        #expect(requests.map(\.machineID) == [Self.remoteID, "local"])
        #expect(requests.map { $0.targets.map(\.pane) } == [["p9"], ["p1", "p2"]])
        #expect(requests.allSatisfy { $0.query == "launch" })
    }

    @Test func streamsEachMachineAsItAnswersAndKeepsSkeletonsForTheRest() async {
        let gate = HerdrSearchGate()
        let model = HerdrSearchModel(
            searcher: { request in
                if request.machineID == Self.remoteID {
                    await gate.wait()
                    return AgentSearchReply(
                        machineID: request.machineID, hits: [Self.hit(Self.remote, "invoices")],
                        milliseconds: 80)
                }
                return AgentSearchReply(
                    machineID: request.machineID,
                    hits: [Self.hit(Self.docs, "docs"), Self.hit(Self.launch, "launch")],
                    milliseconds: 4)
            }, decider: { nil })
        model.query = "launch"
        model.search(agents: Self.agents, hosts: Self.hosts)
        #expect(model.sections.map(\.state) == [.searching, .searching])
        #expect(model.rows.isEmpty)
        await eventually { model.sections[0].state == .ready }
        #expect(model.sections[0].rows.map(\.id) == [Self.docs.id, Self.launch.id])
        #expect(model.sections[0].rows.first?.snippet == "docs")
        #expect(model.sections[1].state == .searching)
        #expect(model.machineProgress.done == 1)
        #expect(model.machineProgress.total == 2)
        await gate.release()
        await eventually { model.sections[1].state == .ready }
        #expect(model.rows.map(\.id) == [Self.docs.id, Self.launch.id, Self.remote.id])
        #expect(!model.isBusy)
    }

    @Test func emptyQueryKeepsSidebarOrderAndAddsSnippets() async {
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(
                    machineID: request.machineID, hits: [Self.hit(Self.docs, "latest prompt")])
            }, decider: { HerdrSearchDecider(probabilities: ["s0": 1]) })
        model.search(agents: [Self.launch, Self.docs], hosts: Self.hosts)
        await eventually { model.sections.first?.state == .ready }
        #expect(model.rows.map(\.id) == [Self.docs.id, Self.launch.id])
        #expect(model.rows.first?.snippet == "latest prompt")
        #expect(model.best == .hidden)
    }

    @Test func followsUpWhileAMachineIsStillReadingHistory() async {
        let calls = HerdrSearchCalls()
        let model = HerdrSearchModel(
            searcher: { request in
                let count = calls.add(request)
                return AgentSearchReply(
                    machineID: request.machineID,
                    hits: count == 1 ? [] : [Self.hit(Self.launch, "late")],
                    pending: count == 1 ? 1 : 0)
            }, decider: { nil })
        model.query = "late"
        model.search(agents: [Self.launch], hosts: Self.hosts)
        await eventually { model.sections[0].state == .ready }
        #expect(calls.all.count == 2)
        #expect(model.rows.map(\.snippet) == ["late"])
    }

    @Test func machineErrorsStayInTheirSection() async {
        let model = HerdrSearchModel(
            searcher: { request in
                if request.machineID == Self.remoteID {
                    return AgentSearchReply(
                        machineID: request.machineID, error: "python3 is not installed there.")
                }
                return AgentSearchReply(
                    machineID: request.machineID, hits: [Self.hit(Self.launch, "ok")])
            }, decider: { nil })
        model.query = "ok"
        model.search(agents: Self.agents, hosts: Self.hosts)
        await eventually { model.sections[1].state != .searching }
        #expect(model.sections[1].state == .failed("python3 is not installed there."))
        await eventually { model.sections[0].state == .ready }
    }

    @Test func staleRepliesAreDropped() {
        let model = HerdrSearchModel(
            searcher: { request in
                try await Task.sleep(for: .seconds(30))
                return AgentSearchReply(machineID: request.machineID)
            }, decider: { nil })
        model.query = "x"
        model.search(agents: [Self.launch], hosts: Self.hosts)
        let stale = model.receive(
            AgentSearchReply(machineID: "local", hits: [Self.hit(Self.launch, "old")]), serial: 0)
        #expect(!stale)
        #expect(model.sections[0].state == .searching)
        model.cancel()
    }

    @Test func jevPicksBecomeBestMatchesAndLeaveTheirMachineSections() async {
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(
                    machineID: request.machineID,
                    hits: [Self.hit(Self.launch, "a"), Self.hit(Self.docs, "b")])
            }, decider: { HerdrSearchDecider(probabilities: ["s1": 0.7, "none": 0.3]) })
        model.query = "app optimizations"
        model.search(agents: [Self.launch, Self.docs], hosts: Self.hosts)
        await eventually { if case .ready = model.best { true } else { false } }
        #expect(model.bestRows.map(\.id) == [Self.docs.id])
        #expect(model.rows.map(\.id) == [Self.docs.id, Self.launch.id])
        #expect(model.usesJev)
    }

    @Test func jevChoosingNoneLeavesKeywordOrder() async {
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(
                    machineID: request.machineID,
                    hits: [Self.hit(Self.launch, "a"), Self.hit(Self.docs, "b")])
            }, decider: { HerdrSearchDecider(probabilities: ["none": 0.8, "s0": 0.2]) })
        model.query = "something unrelated"
        model.search(agents: [Self.launch, Self.docs], hosts: Self.hosts)
        await eventually { model.best == .noMatch }
        #expect(model.rows.map(\.id) == [Self.launch.id, Self.docs.id])
    }

    @Test func enterRunsAChangedQueryThenOpensTheSelectedAgent() async {
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(
                    machineID: request.machineID,
                    hits: [Self.hit(Self.launch, "a"), Self.hit(Self.docs, "b")])
            }, decider: { nil })
        model.query = "launch"
        #expect(model.submit(agents: [Self.launch, Self.docs], hosts: Self.hosts) == nil)
        await eventually { model.sections.first?.state == .ready }
        #expect(model.submit(agents: [Self.launch, Self.docs], hosts: Self.hosts) == Self.launch)
        model.move(1)
        #expect(model.submit(agents: [Self.launch, Self.docs], hosts: Self.hosts) == Self.docs)
        model.move(1)
        #expect(model.selectedRow?.id == Self.launch.id)
    }
}

@Suite struct AgentSearchJevTests {
    static let candidates = (0..<3).map {
        AgentSearchCandidate(id: "row\($0)", meaning: "Claude Code session \($0)")
    }

    @Test func buildsOneChoiceWithANoneOption() throws {
        #expect(AgentSearchJev.request(query: "  ", candidates: Self.candidates) == nil)
        #expect(
            AgentSearchJev.request(query: "x", candidates: Array(Self.candidates.prefix(1)))
                == nil)
        let request = try #require(
            AgentSearchJev.request(query: "app optimizations", candidates: Self.candidates))
        #expect(request.state == .fields(["request": "app optimizations"]))
        guard case .choice(_, let options) = request.questions[AgentSearchJev.question] else {
            Issue.record("expected a choice")
            return
        }
        #expect(options.map(\.id) == ["s0", "s1", "s2", "none"])
        #expect((try? request.validated()) != nil)
    }

    @Test func picksStopAtNoneAndTheThreshold() {
        func picks(_ probabilities: [String: Double]) -> [String] {
            AgentSearchJev.picks(
                JevRouterTests.decision(AgentSearchJev.question, probabilities),
                candidates: Self.candidates)
        }
        #expect(picks(["s1": 0.5, "s2": 0.3, "none": 0.15, "s0": 0.05]) == ["row1", "row2"])
        #expect(picks(["none": 0.7, "s1": 0.3]).isEmpty)
        #expect(picks(["s0": 0.9, "s9": 0.05, "s1": 0.05]) == ["row0"])
        #expect(picks(["s0": 0.3, "s1": 0.3, "s2": 0.3, "none": 0.1]) == ["row0", "row1", "row2"])
    }

    @Test func meaningNamesKindPlaceMachineAndTitle() {
        let meaning = AgentSearchJev.meaning(
            kind: "Codex", project: "billing", branch: "fix/rounding", machine: "devbox",
            title: "Invoice rounding", summary: "Fix the rounding")
        #expect(
            meaning
                == "Codex session in billing on branch fix/rounding (devbox): Invoice rounding. Fix the rounding"
        )
    }
}

@MainActor
@Suite(.serialized) struct SessionSearchCommandTests {
    @Test func commandKOpensSearchOnlyInTheMainWindowOnSessions() {
        let store = HerdrStore()
        let main = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { main.orderOut(nil) }
        main.identifier = NSUserInterfaceItemIdentifier(MainWindowIdentifier.value)
        let other = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { other.orderOut(nil) }

        #expect(!SessionSearchCommand.perform(in: nil, store: store, sessionsOnScreen: { true }))
        #expect(!SessionSearchCommand.perform(in: other, store: store, sessionsOnScreen: { true }))
        #expect(!SessionSearchCommand.perform(in: main, store: store, sessionsOnScreen: { false }))
        #expect(!store.searchPresented)
        #expect(SessionSearchCommand.perform(in: main, store: store, sessionsOnScreen: { true }))
        #expect(store.searchPresented)
    }
}
