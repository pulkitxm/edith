import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

private func agent(
    pane: String = "w1:p1", status: HerdrAgentStatus = .idle, sequence: Int? = 4,
    kind: String = "claude", machineID: String = HerdrHostSnapshot.localID, local: Bool = true,
    category: HerdrPaneCategory = .agent
) -> HerdrAgent {
    HerdrAgent.make(
        machineID: machineID, machineName: local ? "This Mac" : "Box", machineIsLocal: local,
        sshTarget: local ? nil : "box", session: "default", pane: pane, kind: kind,
        status: status, title: "Refactor", workspace: "repo", cwd: "/tmp/repo",
        category: category, stateSequence: sequence)
}

private func observed(
    _ status: HerdrAgentStatus, _ sequence: Int?, kind: String = "claude",
    identity: HerdrAgentIdentity = HerdrAgentIdentity(
        terminalID: "term_1", processGroupID: 123)
) -> HerdrAgentProbe {
    .agent(
        HerdrAgentObservation(
            kind: kind, status: status, sequence: sequence, identity: identity))
}

private func makeHook(agent: HerdrAgent, message: String) -> HerdrAgentHook {
    HerdrAgentHook(
        agent: agent, message: message,
        observation: HerdrAgentObservation(
            kind: agent.kind, status: agent.status, sequence: agent.stateSequence,
            identity: HerdrAgentIdentity(terminalID: "term_1", processGroupID: 123)))
}

private final class ProbeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [String: [HerdrAgentProbe]] = [:]
    private var sentMessages: [String] = []
    private var probed: [String] = []
    var outcome: HerdrPromptOutcome = .submitted

    func queue(_ pane: String, _ probes: HerdrAgentProbe...) {
        lock.withLock { queued[pane, default: []].append(contentsOf: probes) }
    }

    func next(_ hook: HerdrAgentHook) -> HerdrAgentProbe {
        lock.withLock {
            probed.append(hook.pane)
            guard var list = queued[hook.pane], !list.isEmpty else {
                return .unreachable("no script")
            }
            let first = list.removeFirst()
            queued[hook.pane] = list
            return first
        }
    }

    func record(_ hook: HerdrAgentHook) -> HerdrPromptOutcome {
        lock.withLock {
            sentMessages.append("\(hook.pane): \(hook.message)")
            return outcome
        }
    }

    var sent: [String] { lock.withLock { sentMessages } }
    var probes: [String] { lock.withLock { probed } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private actor PublicationGate {
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var waiting = false

    func pause() async {
        waiting = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilPaused() async {
        if waiting { return }
        await withCheckedContinuation { entered = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
        waiting = false
    }
}

private struct HookFixture {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentHooks.\(UUID().uuidString).json")
    let script = ProbeScript()
    let clock = Clock()

    func service(publish: @escaping AgentHookService.Publish = { _ in }) -> AgentHookService {
        let script = script
        let clock = clock
        return AgentHookService(
            url: url, probe: { script.next($0) },
            armProbe: { agent in observed(agent.status, agent.stateSequence, kind: agent.kind) },
            send: { script.record($0) }, publish: publish,
            now: { clock.now })
    }

    func close() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct HerdrAgentHookTests {
    @Test func promptAndProbeCommandsTargetThePaneInItsSession() {
        #expect(
            HerdrAgentPromptCommand.arguments(session: "work", pane: "w2:p3", text: "run tests")
                == ["--session", "work", "agent", "prompt", "w2:p3", "run tests"])
        #expect(
            HerdrAgentPromptCommand.probeArguments(session: "work", pane: "w2:p3")
                == ["--session", "work", "agent", "get", "w2:p3"])
    }

    @Test func parsesAgentGetReplies() {
        let output = """
            {"id":"cli:agent:get","result":{"agent":{"agent":"codex","agent_status":"done",\
            "pane_id":"w1:p1","state_change_seq":12,"terminal_id":"term_1"},"type":"agent_info"}}
            """
        #expect(
            HerdrAgentReply.observation(from: output)
                == HerdrAgentObservation(
                    kind: "codex", status: .done, sequence: 12,
                    identity: HerdrAgentIdentity(terminalID: "term_1")))
        let withSession = output.replacingOccurrences(
            of: #""terminal_id":"term_1""#,
            with:
                #""terminal_id":"term_1","agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"session-1"}"#
        )
        #expect(
            HerdrAgentReply.observation(from: withSession)?.identity.sessionID
                == "herdr:codex|id|session-1")
        #expect(
            HerdrAgentReply.processGroup(
                from: """
                    {"result":{"process_info":{"foreground_process_group_id":123}}}
                    """) == 123)
        #expect(
            HerdrAgentReply.processGroup(
                from: """
                    {"result":{"process_info":{"foreground_process_group_id":123,"shell_pid":123}}}
                    """) == nil)
        #expect(HerdrAgentReply.observation(from: "not json") == nil)
    }

    @Test func mapsHerdrErrorCodesToOutcomes() {
        func outcome(_ code: String) -> HerdrPromptOutcome {
            HerdrPromptOutcome.from(
                HerdrCommandError.commandFailed(
                    #"{"error":{"code":"\#(code)","message":"agent w1:p1 said no"},"id":"x"}"#))
        }
        #expect(outcome("agent_blocked") == .blocked)
        #expect(outcome("agent_not_ready") == .notReady)
        #expect(outcome("agent_not_found") == .gone)
        #expect(outcome("empty_agent_prompt") == .failed("agent w1:p1 said no"))
        #expect(
            HerdrPromptOutcome.from(HerdrCommandError.commandFailed("ssh: timeout"))
                == .failed("ssh: timeout"))
        #expect(HerdrPromptOutcome.blocked.summary == "Skipped: waiting for your input")
    }

    @Test func normalizesMessages() {
        #expect(HerdrAgentPrompt.normalized("  \n ") == nil)
        #expect(HerdrAgentPrompt.normalized("  keep going\n") == "keep going")
    }

    @Test func armingCapturesTheBaseline() {
        let idle = makeHook(agent: agent(status: .idle, sequence: 7), message: "next")
        #expect(idle.baselineSequence == 7)
        #expect(!idle.ran)
        #expect(idle.isArmed)
        let working = makeHook(agent: agent(status: .working), message: "next")
        #expect(working.ran)
    }

    @Test func firesOnlyAfterTheAgentRanAndStopped() {
        let hook = makeHook(agent: agent(status: .idle, sequence: 4), message: "next")
        guard case .keep(let unchanged) = HerdrHookEvaluator.evaluate(hook, observed(.idle, 4))
        else { Issue.record("an idle agent that never ran must not fire"); return }
        #expect(!unchanged.ran)
        guard case .keep(let running) = HerdrHookEvaluator.evaluate(hook, observed(.working, 5))
        else { Issue.record("working keeps the hook armed"); return }
        #expect(running.ran)
        #expect(running.baselineSequence == 5)
        #expect(HerdrHookEvaluator.evaluate(running, observed(.idle, 6)) == .fire(running))
        guard case .keep(let blocked) = HerdrHookEvaluator.evaluate(hook, observed(.blocked, 5))
        else { Issue.record("blocked keeps the hook armed"); return }
        #expect(blocked.ran)
    }

    @Test func firesWhenARunHappenedBetweenPolls() {
        let hook = makeHook(agent: agent(status: .idle, sequence: 4), message: "next")
        #expect(HerdrHookEvaluator.evaluate(hook, observed(.done, 6)) == .fire(hook))
        guard case .keep(let quiet) = HerdrHookEvaluator.evaluate(hook, observed(.idle, 6)) else {
            Issue.record("an idle agent with a moved sequence stays armed"); return
        }
        #expect(quiet.baselineSequence == 6)
        #expect(!quiet.ran)
    }

    @Test func unknownAndUnreachableKeepTheHookUntouched() {
        let hook = makeHook(agent: agent(status: .idle, sequence: 4), message: "next")
        #expect(HerdrHookEvaluator.evaluate(hook, observed(.unknown, 9)) == .keep(hook))
        #expect(HerdrHookEvaluator.evaluate(hook, .unreachable("ssh down")) == .keep(hook))
    }

    @Test func cancelsWhenTheAgentLeavesOrIsReplaced() {
        let hook = makeHook(agent: agent(), message: "next")
        #expect(HerdrHookEvaluator.evaluate(hook, .gone) == .cancel(HerdrHookEvaluator.goneReason))
        #expect(
            HerdrHookEvaluator.evaluate(hook, observed(.idle, 4, kind: "codex"))
                == .cancel(HerdrHookEvaluator.replacedReason))
        #expect(
            HerdrHookEvaluator.evaluate(
                hook,
                observed(
                    .idle, 5,
                    identity: HerdrAgentIdentity(terminalID: "term_1", processGroupID: 456)))
                == .cancel(HerdrHookEvaluator.replacedReason))
        #expect(
            HerdrHookEvaluator.evaluate(hook, observed(.working, 5, kind: "claude-code"))
                != .cancel(HerdrHookEvaluator.replacedReason))
    }

    @Test func broadcastSendsToEveryAgentWithinTheLimit() async {
        final class Gauge: @unchecked Sendable {
            let lock = NSLock()
            var current = 0
            var peak = 0
            func enter() {
                lock.withLock {
                    current += 1; peak = max(peak, current)
                }
            }
            func leave() { lock.withLock { current -= 1 } }
        }
        let gauge = Gauge()
        let agents = (1...7).map { agent(pane: "w1:p\($0)") }
        let outcomes = await HerdrAgentPrompt.broadcast("status?", to: agents, maximumInFlight: 3) {
            text, target in
            gauge.enter()
            try? await Task.sleep(for: .milliseconds(20))
            gauge.leave()
            #expect(text == "status?")
            return target.pane == "w1:p2" ? .blocked : .submitted
        }
        #expect(outcomes.count == 7)
        #expect(outcomes[agents[1].id] == .blocked)
        #expect(outcomes.values.filter(\.delivered).count == 6)
        #expect(gauge.peak <= 3)
    }

    @Test func sendsTheMessageOnceWhenTheAgentFinishes() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        let service = fixture.service()
        let snapshot = try await service.arm(
            HerdrHookArmRequest(agent: agent(status: .idle, sequence: 4), message: " next step "))
        #expect(snapshot.hooks.count == 1)
        #expect(snapshot.hooks[0].message == "next step")
        fixture.script.queue("w1:p1", observed(.idle, 4), observed(.working, 5), observed(.done, 6))
        await service.tick()
        await service.tick()
        #expect(fixture.script.sent.isEmpty)
        await service.tick()
        await service.tick()
        #expect(fixture.script.sent == ["w1:p1: next step"])
        let hook = try #require(await service.list().hooks.first)
        #expect(hook.phase == .sent)
        #expect(hook.detail == "Submitted")
        #expect(hook.settledAt == fixture.clock.now)
        #expect(await service.list().armed(for: hook.agentID) == nil)
        #expect(await service.list().latestSettled(for: hook.agentID) == hook)
    }

    @Test func keepsTheOutcomeWhenHerdrRefusesTheMessage() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        fixture.script.outcome = .blocked
        let service = fixture.service()
        _ = try await service.arm(
            HerdrHookArmRequest(agent: agent(status: .working), message: "next"))
        fixture.script.queue("w1:p1", observed(.idle, 9))
        await service.tick()
        let hook = try #require(await service.list().hooks.first)
        #expect(hook.phase == .skipped)
        #expect(hook.detail == HerdrPromptOutcome.blocked.summary)
    }

    @Test func cancelsWhenTheAgentCloses() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        let service = fixture.service()
        _ = try await service.arm(HerdrHookArmRequest(agent: agent(), message: "next"))
        fixture.script.queue("w1:p1", .gone)
        await service.tick()
        let hook = try #require(await service.list().hooks.first)
        #expect(hook.phase == .cancelled)
        #expect(hook.detail == HerdrHookEvaluator.goneReason)
        #expect(fixture.script.sent.isEmpty)
    }

    @Test func armingAgainReplacesTheArmedHook() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        let service = fixture.service()
        _ = try await service.arm(HerdrHookArmRequest(agent: agent(), message: "first"))
        let snapshot = try await service.arm(HerdrHookArmRequest(agent: agent(), message: "second"))
        #expect(snapshot.hooks.map(\.message) == ["second"])
        let removed = try await service.remove(snapshot.hooks[0].id)
        #expect(removed.hooks.isEmpty)
    }

    @Test func cancellingWhileDeliveryIsPublishedPreventsTheSend() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        let gate = PublicationGate()
        let service = fixture.service { data in
            let snapshot = try? AgentPayload.decode(HerdrHooksSnapshot.self, from: data)
            if snapshot?.hooks.contains(where: { $0.phase == .sending }) == true {
                await gate.pause()
            }
        }
        let armed = try await service.arm(
            HerdrHookArmRequest(agent: agent(status: .working), message: "old"))
        fixture.script.queue("w1:p1", observed(.idle, 5))
        let tick = Task { await service.tick() }
        await gate.waitUntilPaused()
        _ = try await service.remove(armed.hooks[0].id)
        await gate.resume()
        await tick.value
        #expect(fixture.script.sent.isEmpty)
        #expect(await service.list().hooks.isEmpty)
    }

    @Test func replacingWhileDeliveryIsPublishedPreventsTheOldSend() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        let gate = PublicationGate()
        let service = fixture.service { data in
            let snapshot = try? AgentPayload.decode(HerdrHooksSnapshot.self, from: data)
            if snapshot?.hooks.contains(where: { $0.phase == .sending }) == true {
                await gate.pause()
            }
        }
        _ = try await service.arm(
            HerdrHookArmRequest(agent: agent(status: .working), message: "old"))
        fixture.script.queue("w1:p1", observed(.idle, 5))
        let tick = Task { await service.tick() }
        await gate.waitUntilPaused()
        _ = try await service.arm(
            HerdrHookArmRequest(agent: agent(status: .idle, sequence: 5), message: "new"))
        await gate.resume()
        await tick.value
        #expect(fixture.script.sent.isEmpty)
        #expect(await service.list().hooks.map(\.message) == ["new"])
    }

    @Test func saveFailuresDoNotArmOrSend() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        let service = fixture.service()
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: true)
        await #expect(throws: Error.self) {
            try await service.arm(HerdrHookArmRequest(agent: agent(), message: "next"))
        }
        #expect(await service.list().hooks.isEmpty)
        try FileManager.default.removeItem(at: fixture.url)
        _ = try await service.arm(
            HerdrHookArmRequest(agent: agent(status: .working), message: "next"))
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: true)
        fixture.script.queue("w1:p1", observed(.idle, 5))
        await service.tick()
        #expect(fixture.script.sent.isEmpty)
        #expect(await service.list().hooks.first?.phase == .armed)
    }

    @Test func refusesEmptyMessagesAndTerminals() async {
        let fixture = HookFixture()
        defer { fixture.close() }
        let service = fixture.service()
        await #expect(throws: AgentError.self) {
            try await service.arm(HerdrHookArmRequest(agent: agent(), message: "  "))
        }
        await #expect(throws: AgentError.self) {
            try await service.arm(
                HerdrHookArmRequest(agent: agent(category: .terminal), message: "ls"))
        }
    }

    @Test func pollsRemoteMachinesLessOften() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        let service = fixture.service()
        _ = try await service.arm(HerdrHookArmRequest(agent: agent(pane: "w1:p1"), message: "a"))
        _ = try await service.arm(
            HerdrHookArmRequest(
                agent: agent(pane: "w9:p9", machineID: "remote", local: false), message: "b"))
        await service.tick()
        fixture.clock.advance(2)
        await service.tick()
        fixture.clock.advance(AgentHookService.remoteInterval)
        await service.tick()
        #expect(fixture.script.probes.filter { $0 == "w1:p1" }.count == 3)
        #expect(fixture.script.probes.filter { $0 == "w9:p9" }.count == 2)
    }

    @Test func neverResendsAfterARestartMidSend() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        var hook = makeHook(agent: agent(), message: "next")
        hook.phase = .sending
        try AgentPayload.encode(HerdrHooksSnapshot(hooks: [hook])).write(to: fixture.url)
        let service = fixture.service()
        let recovered = try #require(await service.list().hooks.first)
        #expect(recovered.phase == .skipped)
        #expect(recovered.detail == AgentHookService.restartedReason)
        await service.tick()
        #expect(fixture.script.probes.isEmpty)
    }

    @Test func persistsAndPublishesChanges() async throws {
        final class Published: @unchecked Sendable {
            let lock = NSLock()
            var payloads: [Data] = []
        }
        let fixture = HookFixture()
        defer { fixture.close() }
        let published = Published()
        let service = fixture.service()
        await service.start { data in published.lock.withLock { published.payloads.append(data) } }
        _ = try await service.arm(HerdrHookArmRequest(agent: agent(), message: "next"))
        await service.stop()
        let stored = try AgentPayload.decode(
            HerdrHooksSnapshot.self, from: Data(contentsOf: fixture.url))
        #expect(stored.hooks.map(\.message) == ["next"])
        let last = try #require(published.lock.withLock { published.payloads.last })
        #expect(try AgentPayload.decode(HerdrHooksSnapshot.self, from: last) == stored)
        let reloaded = fixture.service()
        #expect(await reloaded.list() == stored)
    }

    @Test func dropsOldSettledHooks() async throws {
        let fixture = HookFixture()
        defer { fixture.close() }
        let service = fixture.service()
        _ = try await service.arm(HerdrHookArmRequest(agent: agent(), message: "old"))
        fixture.script.queue("w1:p1", .gone)
        await service.tick()
        fixture.clock.advance(AgentHookService.settledLifetime + 1)
        let snapshot = try await service.arm(
            HerdrHookArmRequest(agent: agent(pane: "w1:p2"), message: "new"))
        #expect(snapshot.hooks.map(\.message) == ["new"])
    }
}
