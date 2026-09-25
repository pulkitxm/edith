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
    nonisolated static let offlineID = "7A3F0C2E-0000-4000-8000-000000000002"

    nonisolated static func agent(
        _ kind: String, pane: String, cwd: String, title: String, machineID: String = "local"
    ) -> HerdrAgent {
        HerdrAgent.make(
            machineID: machineID, machineName: machineID == "local" ? "This Mac" : "devbox",
            machineIsLocal: machineID == "local", sshTarget: nil, session: "default", pane: pane,
            kind: kind, status: .working, title: title, workspace: "atlas", cwd: cwd)
    }

    nonisolated static func hit(
        _ session: String, kind: AgentTranscriptKind = .claude, cwd: String = "/work/atlas",
        rank: Int = 0, machineID: String = "local", score: Double = 1
    ) -> AgentSearchHit {
        AgentSearchHit(
            machineID: machineID, kind: kind, sessionID: session, path: "/t/\(session).jsonl",
            cwd: cwd, title: "Session \(session)", snippet: "about \(session)",
            summary: "asked about \(session)", lastActivity: 1_790_000_000, score: score,
            placeRank: rank)
    }

    nonisolated static var hosts: [HerdrHostSnapshot] {
        [
            .local(
                herdrPresent: true,
                agents: [agent("Claude Code", pane: "p1", cwd: "/work/atlas", title: "✳ Launch")]),
            HerdrHostSnapshot(
                id: remoteID, name: "devbox", isLocal: false, herdrPresent: true,
                reachable: true),
            HerdrHostSnapshot(
                id: offlineID, name: "buildbox", isLocal: false, herdrPresent: false,
                reachable: false),
        ]
    }

    func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func streamsEachMachineAsItAnswersAndKeepsSkeletonsForTheRest() async {
        let gate = HerdrSearchGate()
        let model = HerdrSearchModel(
            searcher: { request in
                if request.machineID == Self.remoteID {
                    await gate.wait()
                    return AgentSearchReply(
                        machineID: request.machineID,
                        hits: [Self.hit("r1", kind: .codex, machineID: Self.remoteID)],
                        milliseconds: 80)
                }
                return AgentSearchReply(
                    machineID: request.machineID, hits: [Self.hit("l1"), Self.hit("l2", rank: 1)],
                    milliseconds: 4)
            }, decider: { nil })
        model.query = "launch"
        model.search(hosts: Self.hosts)
        #expect(model.sections.map(\.state) == [.searching, .searching, .offline])

        await eventually { model.sections[0].state == .ready }
        #expect(model.sections[0].rows.map(\.id) == ["local|claude|l1", "local|claude|l2"])
        #expect(model.sections[1].state == .searching)
        #expect(model.isBusy)
        #expect(model.machineProgress.done == 1)
        #expect(model.machineProgress.total == 2)
        #expect(model.best == .hidden)

        await gate.release()
        await eventually { model.sections[1].state == .ready }
        #expect(model.sections[1].rows.map(\.hit?.sessionID) == ["r1"])
        #expect(model.sections[1].milliseconds == 80)
        #expect(!model.isBusy)
        #expect(model.rows.count == 3)
    }

    @Test func followsUpWhileAMachineIsStillReadingTranscripts() async {
        let calls = HerdrSearchCalls()
        let model = HerdrSearchModel(
            searcher: { request in
                let count = calls.add(request)
                return AgentSearchReply(
                    machineID: request.machineID,
                    hits: count == 1 ? [] : [Self.hit("late")], pending: count == 1 ? 40 : 0)
            }, decider: { nil })
        model.query = "late"
        model.search(hosts: [.local(herdrPresent: true)])
        await eventually { model.sections[0].state == .ready }
        #expect(calls.all.count == 2)
        #expect(model.sections[0].rows.map(\.hit?.sessionID) == ["late"])
    }

    @Test func machineErrorsStayInTheirSection() async {
        let model = HerdrSearchModel(
            searcher: { request in
                if request.machineID == Self.remoteID {
                    return AgentSearchReply(
                        machineID: request.machineID, error: "python3 is not installed there.")
                }
                return AgentSearchReply(machineID: request.machineID, hits: [Self.hit("ok")])
            }, decider: { nil })
        model.search(hosts: Array(Self.hosts.prefix(2)))
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
        model.search(hosts: [.local(herdrPresent: true)])
        let stale = model.receive(
            AgentSearchReply(machineID: "local", hits: [Self.hit("old")]), serial: 0)
        #expect(!stale)
        #expect(model.sections[0].state == .searching)
        model.cancel()
    }

    @Test func jevPicksBecomeBestMatchesAndLeaveTheirMachineSections() async {
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(
                    machineID: request.machineID,
                    hits: [Self.hit("a"), Self.hit("b", rank: 1), Self.hit("c", rank: 2)])
            }, decider: { HerdrSearchDecider(probabilities: ["s2": 0.6, "s0": 0.3, "none": 0.1]) })
        model.query = "app optimizations"
        model.search(hosts: [.local(herdrPresent: true)])
        await eventually { if case .ready = model.best { true } else { false } }
        #expect(model.bestRows.map(\.hit?.sessionID) == ["c", "a"])
        #expect(model.visibleRows(in: model.sections[0]).map(\.hit?.sessionID) == ["b"])
        #expect(model.rows.map(\.hit?.sessionID) == ["c", "a", "b"])
        #expect(model.usesJev)
    }

    @Test func jevChoosingNoneLeavesKeywordOrder() async {
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(
                    machineID: request.machineID, hits: [Self.hit("a"), Self.hit("b", rank: 1)])
            }, decider: { HerdrSearchDecider(probabilities: ["none": 0.8, "s0": 0.2]) })
        model.query = "something unrelated"
        model.search(hosts: [.local(herdrPresent: true)])
        await eventually { model.best == .noMatch }
        #expect(model.rows.map(\.hit?.sessionID) == ["a", "b"])
    }

    @Test func emptyQuerySkipsJevAndListsLiveAgentsFirst() async {
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(machineID: request.machineID, hits: [Self.hit("recent", rank: 3)])
            }, decider: { HerdrSearchDecider(probabilities: ["s0": 1]) })
        model.search(hosts: [Self.hosts[0]])
        #expect(model.rows.map(\.id) == ["local|default|p1"])
        await eventually { model.sections[0].state == .ready }
        #expect(model.best == .hidden)
        #expect(model.rows.map(\.id) == ["local|default|p1", "local|claude|recent"])
    }

    @Test func enterRunsAChangedQueryThenOpensOrResumesTheSelection() async {
        let host = Self.hosts[0]
        let model = HerdrSearchModel(
            searcher: { request in
                AgentSearchReply(
                    machineID: request.machineID,
                    hits: [Self.hit("live"), Self.hit("old", rank: 1)])
            }, decider: { nil })
        model.query = "launch"
        #expect(model.submit(hosts: [host]) == nil)
        await eventually { model.sections[0].state == .ready }
        guard case .open(let agent) = model.submit(hosts: [host]) else {
            Issue.record("expected the live agent")
            return
        }
        #expect(agent.pane == "p1")
        model.move(1)
        #expect(model.submit(hosts: [host]) == .resume(Self.hit("old", rank: 1), host))
        model.move(1)
        #expect(model.selectedRow?.hit?.sessionID == "live")
        model.move(-1)
        #expect(model.selectedRow?.hit?.sessionID == "old")
    }
}

@Suite struct HerdrSearchPlanTests {
    typealias Fixture = HerdrSearchModelTests

    @Test func linksHitsToLiveAgentsByKindPlaceAndRecency() {
        let host = HerdrHostSnapshot.local(
            herdrPresent: true,
            agents: [
                Fixture.agent("Claude Code", pane: "p2", cwd: "/work/atlas/", title: "B"),
                Fixture.agent("Claude Code", pane: "p1", cwd: "/work/atlas", title: "A"),
                Fixture.agent("Codex", pane: "p3", cwd: "/srv/billing", title: "Invoices"),
                HerdrAgent.make(
                    machineID: "local", machineName: "This Mac", machineIsLocal: true,
                    sshTarget: nil, session: "default", pane: "t1", kind: "Terminal",
                    status: .idle, title: "zsh atlas", workspace: "atlas", cwd: "/work/atlas",
                    category: .terminal),
            ])
        let rows = HerdrSearchPlan.rows(
            for: host,
            hits: [
                Fixture.hit("newest"), Fixture.hit("older", rank: 1),
                Fixture.hit("oldest", rank: 2),
                Fixture.hit("pi", kind: .pi),
            ], query: "atlas")
        #expect(rows.map(\.agent?.pane) == ["p3", "p1", "p2", nil, nil])
        #expect(rows.map(\.hit?.sessionID) == [nil, "newest", "older", "oldest", "pi"])
    }

    @Test func liveAgentsMatchTheirTitleSpaceAndFolder() {
        let host = HerdrHostSnapshot.local(
            herdrPresent: true,
            agents: [
                Fixture.agent("Codex", pane: "p3", cwd: "/srv/billing", title: "Invoice fixes"),
                Fixture.agent("Claude Code", pane: "p1", cwd: "/work/atlas", title: "Launch"),
            ])
        let rows = HerdrSearchPlan.rows(for: host, hits: [], query: "invoices billing")
        #expect(rows.map(\.agent?.pane) == ["p3"])
        #expect(rows[0].project == "billing")
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

@Suite struct HerdrSessionResumeTests {
    @Test func resumeArgumentsWrapTheLaunchFlags() {
        let defaults = UserDefaults(suiteName: "test.herdr.resume.\(UUID().uuidString)")!
        let claude = HerdrLaunchOperations.agentLaunch(
            kind: "Claude Code", name: "claude", pane: "w1:p1",
            options: AgentLaunchOptions(model: "opus"),
            resuming: AgentTranscriptKind.claude.resume(sessionID: "abc", path: "/x"),
            defaults: defaults)
        #expect(claude.local.suffix(2) == ["--resume", "abc"])
        #expect(claude.remote(.linux).contains("--resume abc"))
        let codex = HerdrLaunchOperations.agentLaunch(
            kind: "Codex", name: "codex", pane: "w1:p1", options: AgentLaunchOptions(model: "gpt"),
            resuming: AgentTranscriptKind.codex.resume(sessionID: "def", path: "/y"),
            defaults: defaults)
        let joined = codex.local.joined(separator: " ")
        #expect(joined.contains("resume def -m gpt"))
    }

    @MainActor
    @Test func resumeOpensTheNewPaneAsATab() async throws {
        let store = HerdrStore(
            sessionResumer: { hit, machine in
                #expect(machine == nil)
                #expect(hit.sessionID == "abc")
                return HerdrCreatedPane(workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p4")
            })
        let hit = HerdrSearchModelTests.hit("abc")
        try await store.resumeSession(hit, on: .local(herdrPresent: true))
        let opened = try #require(store.sessions.last)
        #expect(opened.agent.pane == "w2:p4")
        #expect(opened.agent.title == "Session abc")
        #expect(opened.agent.kind == "Claude Code")
        #expect(opened.agent.cwd == "/work/atlas")
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
