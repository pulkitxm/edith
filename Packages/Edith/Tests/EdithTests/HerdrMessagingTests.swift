import Foundation
import Testing

@testable import Edith
@testable import EdithKit

private func agent(
    _ pane: String, _ status: HerdrAgentStatus, machine: String = HerdrHostSnapshot.localID,
    category: HerdrPaneCategory = .agent
) -> HerdrAgent {
    HerdrAgent.make(
        machineID: machine, machineName: machine == HerdrHostSnapshot.localID ? "This Mac" : "Box",
        machineIsLocal: machine == HerdrHostSnapshot.localID, sshTarget: nil, session: "default",
        pane: pane, kind: "codex", status: status, title: "Agent \(pane)", workspace: "repo",
        cwd: "/tmp", category: category, stateSequence: 1)
}

private func hook(_ agent: HerdrAgent, _ message: String) -> HerdrAgentHook {
    HerdrAgentHook(
        agent: agent, message: message,
        observation: HerdrAgentObservation(
            kind: agent.kind, status: agent.status, sequence: agent.stateSequence,
            identity: HerdrAgentIdentity(terminalID: "term_1", processGroupID: 123)),
        schedule: .whenFinished)
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sentValue: [(String, [String])] = []
    private var armedValue: [(String, String)] = []

    func send(_ text: String, _ agents: [HerdrAgent]) -> [String: HerdrPromptOutcome] {
        lock.withLock { sentValue.append((text, agents.map(\.pane))) }
        return Dictionary(uniqueKeysWithValues: agents.map { ($0.id, .submitted) })
    }

    func arm(_ text: String, _ agent: HerdrAgent) -> HerdrHooksSnapshot {
        lock.withLock { armedValue.append((text, agent.pane)) }
        return HerdrHooksSnapshot(hooks: [hook(agent, text)])
    }

    var sent: [(String, [String])] { lock.withLock { sentValue } }
    var armed: [(String, String)] { lock.withLock { armedValue } }
}

@MainActor
struct HerdrMessagingTests {
    private let fleet = [
        agent("w1:p1", .working), agent("w1:p2", .idle), agent("w1:p3", .done),
        agent("w1:p4", .blocked), agent("w1:p5", .unknown),
        agent("w1:p6", .working, category: .terminal),
    ]

    private func messaging(_ recorder: Recorder, armFails: Bool = false) -> HerdrMessaging {
        HerdrMessaging(
            broadcaster: { recorder.send($0, $1) },
            arm: { text, agent, _ in
                if armFails { throw AgentError(.unavailable, "The agent is still starting.") }
                return recorder.arm(text, agent)
            },
            remove: { _ in HerdrHooksSnapshot() })
    }

    @Test func groupsPickWorkingOrStoppedAgentsAndNeverTerminals() {
        #expect(HerdrBroadcastGroup.working.recipients(from: fleet).map(\.pane) == ["w1:p1"])
        #expect(
            HerdrBroadcastGroup.stopped.recipients(from: fleet).map(\.pane) == ["w1:p2", "w1:p3"])
    }

    @Test func composingAGroupFreezesItsRecipients() {
        let messaging = messaging(Recorder())
        messaging.compose(.stopped, from: fleet)
        let draft = messaging.draft
        #expect(draft?.recipients.map(\.pane) == ["w1:p2", "w1:p3"])
        #expect(draft?.title == "Message Stopped Agents")
        #expect(draft?.single == nil)
        messaging.draft = nil
        messaging.compose(.working, from: [agent("w1:p9", .idle)])
        #expect(messaging.draft == nil)
    }

    @Test func composingForOneAgentOffersWhenItFinishes() {
        let messaging = messaging(Recorder())
        messaging.compose(to: fleet[1], delivery: .whenFinished)
        #expect(messaging.draft?.single == fleet[1])
        #expect(messaging.draft?.delivery == .whenFinished)
        messaging.draft = nil
        messaging.compose(to: fleet[1], presenterID: "detached-w1:p2")
        #expect(messaging.draft?.presenterID == "detached-w1:p2")
        messaging.draft = nil
        messaging.compose(to: fleet[5])
        #expect(messaging.draft == nil)
    }

    @Test func sendingTrimsAndSkipsEmptyMessages() async {
        let recorder = Recorder()
        let messaging = messaging(recorder)
        #expect(await messaging.send("   ", to: fleet).isEmpty)
        let outcomes = await messaging.send(" keep going \n", to: Array(fleet.prefix(2)))
        #expect(outcomes.count == 2)
        #expect(recorder.sent.map(\.0) == ["keep going"])
        #expect(recorder.sent.first?.1 == ["w1:p1", "w1:p2"])
    }

    @Test func armingAdoptsTheReturnedHooks() async {
        let recorder = Recorder()
        let messaging = messaging(recorder)
        #expect(await messaging.arm("run the tests", for: fleet[1], schedule: .whenFinished))
        #expect(messaging.armedHook(for: fleet[1].id)?.message == "run the tests")
        #expect(recorder.armed.map(\.1) == ["w1:p2"])
        await messaging.remove(UUID())
        #expect(messaging.armedHook(for: fleet[1].id) == nil)
    }

    @Test func armingReportsTheBackgroundAgentError() async {
        let messaging = messaging(Recorder(), armFails: true)
        #expect(!(await messaging.arm("run the tests", for: fleet[1], schedule: .whenFinished)))
        #expect(messaging.errorMessage == "The agent is still starting.")
    }

    @Test func hooksSnapshotSeparatesWaitingAndFinished() {
        var sent = hook(fleet[1], "old")
        sent.settle(.sent, "Submitted", at: Date(timeIntervalSince1970: 100))
        var newer = hook(fleet[1], "newer")
        newer.settle(.skipped, "Skipped", at: Date(timeIntervalSince1970: 200))
        let waiting = hook(fleet[1], "next")
        let snapshot = HerdrHooksSnapshot(hooks: [sent, waiting, newer])
        #expect(snapshot.armed(for: fleet[1].id) == waiting)
        #expect(snapshot.latestSettled(for: fleet[1].id) == newer)
        #expect(snapshot.armed(for: fleet[0].id) == nil)
    }

    @Test func storeOffersOnlyFilteredAgentsForMessages() {
        let store = HerdrStore()
        store.apply([
            HerdrHostSnapshot(
                id: HerdrHostSnapshot.localID, name: "This Mac", isLocal: true, sshTarget: nil,
                herdrPresent: true, reachable: true, agents: Array(fleet.prefix(3))),
            HerdrHostSnapshot(
                id: "box", name: "Box", isLocal: false, sshTarget: "box", herdrPresent: true,
                reachable: true, agents: [agent("w2:p1", .working, machine: "box")]),
        ])
        store.machineFilter = "box"
        #expect(
            HerdrBroadcastGroup.working.recipients(from: store.filteredAgents).map(\.pane)
                == ["w2:p1"])
        store.machineFilter = "missing"
        #expect(HerdrBroadcastGroup.working.recipients(from: store.filteredAgents).isEmpty)
        #expect(!store.listedAgents.isEmpty)
    }
}
