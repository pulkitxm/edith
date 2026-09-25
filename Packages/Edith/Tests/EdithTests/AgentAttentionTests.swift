import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

private final class AttentionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedScreen = ""
    private var storedProbes: [HerdrAttentionProbe] = []
    private var storedOpened: [HerdrOpenRequest] = []
    private var storedRequests: [JevRequest] = []
    private var storedClients = 0

    var screen: String {
        get { lock.withLock { storedScreen } }
        set { lock.withLock { storedScreen = newValue } }
    }
    var probes: [HerdrAttentionProbe] { lock.withLock { storedProbes } }
    var opened: [HerdrOpenRequest] { lock.withLock { storedOpened } }
    var requests: [JevRequest] { lock.withLock { storedRequests } }
    var clients: Int { lock.withLock { storedClients } }

    func probe(_ probes: [HerdrAttentionProbe]) { lock.withLock { storedProbes += probes } }
    func open(_ request: HerdrOpenRequest) { lock.withLock { storedOpened.append(request) } }
    func ask(_ request: JevRequest) { lock.withLock { storedRequests.append(request) } }
    func makeClient() { lock.withLock { storedClients += 1 } }
}

private struct ScriptedJev: JevDeciding {
    let recorder: AttentionRecorder
    let answers: [String: JevAnswer]

    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        recorder.ask(request)
        return JevDecision(
            response: JevResponse(model: "jev-latest", answers: answers), milliseconds: 4)
    }
}

private struct EmptyKeyStore: JevKeyStore {
    func read() -> JevKeyRead { .missing }
    func write(_ key: String?) -> Bool { true }
}

private struct AttentionFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let recorder = AttentionRecorder()
    let service: AgentNotificationService
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    init(
        changes: Int? = nil, appRunning: Bool = false,
        decider: (@Sendable (AttentionRecorder) async -> JevDeciding?)? = nil
    ) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentAttention.\(UUID().uuidString)")
        suite = "AgentAttention.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: AppStorageKeys.Tabs.herdrEnabled)
        let recorder = recorder
        service = AgentNotificationService(
            url: root.appendingPathComponent("outbox.json"), defaults: defaults, changed: {},
            attention: AgentAttention(
                inspect: { probes in
                    recorder.probe(probes)
                    return Dictionary(
                        uniqueKeysWithValues: probes.map { probe in
                            (
                                probe.agent.id,
                                HerdrAttentionEvidence(
                                    screen: HerdrPaneScreen(raw: recorder.screen),
                                    changes: probe.countChanges ? changes : nil)
                            )
                        })
                },
                decider: { await decider?(recorder) },
                appIsRunning: { appRunning },
                openAgent: { recorder.open($0) }))
    }

    func close() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func agent(_ status: HerdrAgentStatus, pane: String = "p1") -> HerdrAgent {
        HerdrAgent(
            id: "local|s|\(pane)", machineID: "local", machineName: "This Mac",
            machineIsLocal: true, sshTarget: nil, session: "s", pane: pane, kind: "Claude Code",
            status: status, title: "Fix login", workspace: "edith", cwd: "/work/edith")
    }

    func observe(_ agents: [HerdrAgent], reachable: Bool = true, minutes: Double = 0)
        async throws -> [AgentNotificationDelivery]
    {
        let host = HerdrHostSnapshot(
            id: "local", name: "This Mac", isLocal: true, herdrPresent: true,
            reachable: reachable, agents: agents)
        let now = start.addingTimeInterval(minutes * 60)
        try await service.evaluateSessions([host], now: now)
        return try await service.pending(now: now)
    }
}

@Suite struct AgentAttentionTests {
    @Test func aBlockedAgentAsksForApprovalWithThePromptFromItsScreen() async throws {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        fixture.recorder.screen =
            "Editing Login.swift\n│ Do you want to make this edit to Login.swift?\n│ ❯ 1. Yes"
        #expect(try await fixture.observe([fixture.agent(.working)]).isEmpty)
        let deliveries = try await fixture.observe([fixture.agent(.blocked)])
        let notification = try #require(deliveries.first?.notification)
        #expect(deliveries.map(\.identifier) == ["session.blocked.local|s|p1"])
        #expect(notification.title == "Claude Code needs approval")
        #expect(
            notification.body
                == "Fix login in edith on This Mac: Do you want to make this edit to Login.swift?")
        #expect(
            notification.action
                == HerdrOpenRequest(agentID: "local|s|p1", hostID: "local", view: .agent))
        #expect(AgentNotification(userInfo: notification.userInfo) == notification)
    }

    @Test func aFinishedAgentWithChangesIsReadyForReview() async throws {
        let fixture = AttentionFixture(changes: 7)
        defer { fixture.close() }
        fixture.recorder.screen = "All 42 tests passed, 0 failed\nDone."
        _ = try await fixture.observe([fixture.agent(.working)])
        let notification = try #require(
            try await fixture.observe([fixture.agent(.done)]).first?.notification)
        #expect(notification.identifier == "session.finished.local|s|p1")
        #expect(notification.title == "Claude Code finished")
        #expect(
            notification.body
                == "Fix login in edith on This Mac: ready for review, 7 files changed, click to review"
        )
        #expect(notification.action?.view == .diff)
        #expect(fixture.recorder.probes.map(\.countChanges) == [true])
        #expect(fixture.recorder.opened.isEmpty)
    }

    @Test func openingTheDiffOnFinishNeedsTheAppRunning() async throws {
        let fixture = AttentionFixture(changes: 2, appRunning: true)
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: AgentSettingsKeys.openDiffWhenFinished)
        _ = try await fixture.observe([fixture.agent(.working)])
        let notification = try #require(
            try await fixture.observe([fixture.agent(.idle)]).first?.notification)
        #expect(
            notification.body == "Fix login in edith on This Mac: ready for review, 2 files changed"
        )
        #expect(
            fixture.recorder.opened
                == [HerdrOpenRequest(agentID: "local|s|p1", hostID: "local", view: .diff)])
    }

    @Test func anErrorOnScreenTurnsAFinishIntoAnErrorAlert() async throws {
        let fixture = AttentionFixture(changes: 0)
        defer { fixture.close() }
        fixture.recorder.screen = "Compiling\nerror: build failed with 3 errors"
        _ = try await fixture.observe([fixture.agent(.working)])
        let notification = try #require(
            try await fixture.observe([fixture.agent(.done)]).first?.notification)
        #expect(notification.identifier == "session.error.local|s|p1")
        #expect(notification.title == "Claude Code hit an error")
        #expect(notification.body.hasSuffix(": error: build failed with 3 errors"))
    }

    @Test func unknownFlickersAreNotTransitions() async throws {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        _ = try await fixture.observe([fixture.agent(.working)])
        _ = try await fixture.observe([fixture.agent(.unknown)])
        #expect(try await fixture.observe([fixture.agent(.working)]).isEmpty)
        #expect(fixture.recorder.probes.isEmpty)
        _ = try await fixture.observe([fixture.agent(.unknown)])
        let deliveries = try await fixture.observe([fixture.agent(.done)])
        #expect(deliveries.map(\.identifier) == ["session.finished.local|s|p1"])
    }

    @Test func disappearedAgentsAreForgottenButUnreachableHostsKeepTheirState() async throws {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        _ = try await fixture.observe([fixture.agent(.working)])
        _ = try await fixture.observe([])
        #expect(try await fixture.observe([fixture.agent(.done)]).isEmpty)
        _ = try await fixture.observe([fixture.agent(.working)])
        _ = try await fixture.observe([], reachable: false)
        #expect(try await fixture.observe([fixture.agent(.done)]).count == 1)
    }

    @Test func terminalsNeverNotify() async throws {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        var terminal = fixture.agent(.working)
        terminal.category = .terminal
        _ = try await fixture.observe([terminal])
        terminal.status = .blocked
        #expect(try await fixture.observe([terminal]).isEmpty)
    }

    @Test func aStuckAgentIsReportedOnceAfterTheScreenStopsChanging() async throws {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: AgentSettingsKeys.notifyWhenStuck)
        fixture.recorder.screen = "Running migrations"
        let working = [fixture.agent(.working)]
        _ = try await fixture.observe(working)
        _ = try await fixture.observe(working, minutes: 5)
        #expect(fixture.recorder.probes.isEmpty)
        #expect(try await fixture.observe(working, minutes: 10).isEmpty)
        fixture.recorder.screen = "Seeding tables"
        #expect(try await fixture.observe(working, minutes: 20).isEmpty)
        let notification = try #require(
            try await fixture.observe(working, minutes: 30).first?.notification)
        #expect(notification.identifier == "session.stuck.local|s|p1")
        #expect(notification.title == "Claude Code looks stuck")
        #expect(notification.body.hasSuffix(": no screen change in 10 minutes"))
        _ = try await fixture.observe(working, minutes: 45)
        #expect(fixture.recorder.probes.count == 3)
    }

    @Test func turningASettingOffPurgesItsNotifications() async throws {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        _ = try await fixture.observe([
            fixture.agent(.working), fixture.agent(.working, pane: "p2"),
        ])
        let both = try await fixture.observe([
            fixture.agent(.blocked), fixture.agent(.done, pane: "p2"),
        ])
        #expect(both.count == 2)
        fixture.defaults.set(false, forKey: AgentSettingsKeys.notifyWhenFinished)
        #expect(
            try await fixture.service.pending(now: fixture.start).map(\.identifier)
                == ["session.blocked.local|s|p1"])
        fixture.defaults.set(false, forKey: AppStorageKeys.Tabs.herdrEnabled)
        #expect(try await fixture.service.pending(now: fixture.start).isEmpty)
    }

    @Test func jevCannotSuppressAPermissionPromptTheRulesFound() async throws {
        let fixture = AttentionFixture { recorder in
            ScriptedJev(
                recorder: recorder,
                answers: [
                    "state": JevAnswer(
                        type: "choice", choice: "working", probabilities: ["working": 0.95]),
                    "interrupt": JevAnswer(type: "noul", noul: 0.05),
                    "need": JevAnswer(
                        type: "choice", choice: "nothing", probabilities: ["nothing": 0.9]),
                ])
        }
        defer { fixture.close() }
        fixture.recorder.screen = "token=typesafe-test-value\nAllow command? (y/n)"
        _ = try await fixture.observe([fixture.agent(.working)])
        let notification = try #require(
            try await fixture.observe([fixture.agent(.blocked)]).first?.notification)
        #expect(notification.title == "Claude Code needs approval")
        let request = try #require(fixture.recorder.requests.first)
        guard case .fields(let fields) = request.state else {
            Issue.record("expected field state")
            return
        }
        #expect(fields["screen"]?.contains("typesafe-test-value") == false)
        #expect(Set(request.questions.keys) == ["state", "interrupt", "need"])
    }

    @Test func jevCannotSilenceAnAgentWaitingForAnAnswer() async throws {
        let fixture = AttentionFixture { recorder in
            ScriptedJev(
                recorder: recorder,
                answers: [
                    "state": JevAnswer(
                        type: "choice", choice: "working", probabilities: ["working": 0.97]),
                    "interrupt": JevAnswer(type: "noul", noul: 0.02),
                    "need": JevAnswer(
                        type: "choice", choice: "nothing", probabilities: ["nothing": 0.97]),
                ])
        }
        defer { fixture.close() }
        fixture.recorder.screen = "Which database should the migration target?"
        _ = try await fixture.observe([fixture.agent(.working)])
        let notification = try #require(
            try await fixture.observe([fixture.agent(.blocked)]).first?.notification)
        #expect(notification.title == "Claude Code needs an answer")
    }

    @Test func jevCanTurnAQuietFinishIntoAnError() async throws {
        let fixture = AttentionFixture(changes: 3) { recorder in
            ScriptedJev(
                recorder: recorder,
                answers: [
                    "state": JevAnswer(
                        type: "choice", choice: "error", probabilities: ["error": 0.8]),
                    "interrupt": JevAnswer(type: "noul", noul: 0.9),
                    "need": JevAnswer(
                        type: "choice", choice: "error", probabilities: ["error": 0.8]),
                    "ready_for_review": JevAnswer(type: "noul", noul: 0.1),
                ])
        }
        defer { fixture.close() }
        fixture.recorder.screen = "The migration could not reach the database."
        _ = try await fixture.observe([fixture.agent(.working)])
        let notification = try #require(
            try await fixture.observe([fixture.agent(.done)]).first?.notification)
        #expect(notification.title == "Claude Code hit an error")
        #expect(notification.action?.view == .agent)
        #expect(fixture.recorder.requests.first?.questions["ready_for_review"] != nil)
    }

    @Test func noKeyMeansNoJevCallAndTheRulesStillNotify() async throws {
        let recorder = AttentionRecorder()
        let engine = JevEngine(
            store: EmptyKeyStore(),
            makeClient: { key in
                recorder.makeClient()
                return JevClient(apiKey: key, baseURL: URL(string: "http://127.0.0.1:9")!)
            })
        let fixture = AttentionFixture { _ in await engine.isConfigured ? engine : nil }
        defer { fixture.close() }
        _ = try await fixture.observe([fixture.agent(.working)])
        #expect(try await fixture.observe([fixture.agent(.blocked)]).count == 1)
        #expect(recorder.clients == 0)
        #expect(fixture.recorder.requests.isEmpty)
    }

    @Test func rulesReadExplainFlagsAndScreenText() throws {
        let explain = try #require(
            HerdrAgentExplain.parse(
                #"{"result":{"explain":{"agent":"codex","state":"blocked","visible_blocker":true,"visible_idle":false,"matched_rule":{"id":"prompt_box"}}}}"#
            ))
        #expect(explain.visibleBlocker && explain.rule == "prompt_box")
        #expect(HerdrAgentExplain.parse(#"{"error":{"code":"agent_not_found"}}"#) == nil)
        func verdict(
            _ event: HerdrAttentionEvent, _ screen: String, _ explain: HerdrAgentExplain? = nil
        ) -> HerdrAttentionState {
            HerdrAttentionClassifier.verdict(
                event: event,
                evidence: HerdrAttentionEvidence(
                    screen: HerdrPaneScreen(raw: screen, explain: explain))
            ).state
        }
        #expect(verdict(.stalled, "Which branch should I use?", explain) == .waitingInput)
        #expect(verdict(.stalled, "Waiting", HerdrAgentExplain(visibleIdle: true)) == .done)
        #expect(verdict(.stalled, "Reading files") == .working)
        #expect(verdict(.blocked, "Run cargo test? [y/N]") == .permissionPrompt)
        #expect(verdict(.finished, "thread 'main' panicked at src/lib.rs:4") == .error)
        #expect(verdict(.finished, "Build failed: 2 errors") == .error)
        #expect(verdict(.finished, "3 tests failed") == .error)
        #expect(verdict(.finished, "Summary of the fixed failed test") == .done)
        #expect(verdict(.finished, "This will allow guests\nto sign in\nb\nc\nd") == .done)
    }

    @Test func redactionRemovesCredentialsBeforeTheScreenIsUsed() {
        let key =
            "-----BEGIN " + "OPENSSH PRIVATE" + " KEY-----\nabc\n-----END "
            + "OPENSSH PRIVATE KEY-----"
        let text = """
            Authorization: Bearer typesafe-test-bearer-value
            OPENAI=sk-typesafe-test-key and ghp_typesafeTestValue github_pat_typesafe_test_value
            AKIATESTTESTTEST xoxb-typesafe-test-value password=hunter-test api_key: 'typesafe'
            \(key)
            """
        let redacted = JevRedaction.redact(text)
        for secret in [
            "typesafe-test-bearer-value", "sk-typesafe", "ghp_", "github_pat_", "AKIATEST", "xoxb-",
            "hunter-test", "'typesafe'", "abc",
        ] {
            #expect(!redacted.contains(secret), "\(secret) survived")
        }
        #expect(redacted.contains("Bearer [redacted]"))
        #expect(redacted.contains("password=[redacted]"))
        #expect(JevRedaction.tail(String(repeating: "a", count: 5_000)).count == 3_000)
    }

    @Test func theReaderAsksHerdrForTheVisibleTailAndCountsChangesOnlyWhenAsked() async {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        var calls: [String] = []
        let evidence = await HerdrPaneReader.collect(
            [
                HerdrAttentionProbe(agent: fixture.agent(.done), countChanges: true),
                HerdrAttentionProbe(
                    agent: fixture.agent(.blocked, pane: "p2"), countChanges: false),
            ]
        ) { arguments in
            calls.append(arguments.joined(separator: " "))
            return arguments.contains("explain") ? #"{"state":"idle","visible_idle":true}"# : "Done"
        } changes: { path in
            path == "/work/edith" ? 4 : nil
        }
        #expect(evidence["local|s|p1"]?.changes == 4)
        #expect(evidence["local|s|p2"]?.changes == nil)
        #expect(evidence["local|s|p1"]?.screen?.explain?.visibleIdle == true)
        #expect(calls.first == "--session s pane read p1 --source visible --lines 40")
        #expect(calls.count == 4)
    }

    @Test func quinjetStatusCountsTheWorktreeChanges() async throws {
        let client = QuinjetClient { arguments in
            #expect(arguments == ["-C", "/work/edith", "status", "--json"])
            return Data(
                #"{"branch":{"head":"main"},"changes":[{"path":"a.swift","area":"worktree","status":"modified"},{"path":"b.swift","area":"index","status":"added"}]}"#
                    .utf8)
        }
        #expect(try await client.changeCount(at: "/work/edith") == 2)
    }

    @Test func openRequestsTravelThroughDefaultsAndTheIPCTheAppObserves() {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        let request = HerdrOpenRequest(agentID: "local|s|p1", hostID: "local", view: .diff)
        var posted: [Notification.Name] = []
        HerdrOpenRequests.submit(
            request, defaults: fixture.defaults, now: fixture.start, post: { posted.append($0) })
        #expect(posted == [IPC.Name.requestOpenHerdrAgent])
        #expect(HerdrOpenRequests.take(defaults: fixture.defaults, now: fixture.start) == request)
        #expect(HerdrOpenRequests.take(defaults: fixture.defaults, now: fixture.start) == nil)
        HerdrOpenRequests.submit(
            request, defaults: fixture.defaults, now: fixture.start, post: { _ in })
        #expect(
            HerdrOpenRequests.take(defaults: fixture.defaults, now: fixture.start + 600) == nil)
        let app = CLIWiringTests.swiftFiles(in: "Edith").joined()
        let kit = CLIWiringTests.swiftFiles(in: "EdithKit").joined()
        #expect(app.contains("IPC.observe(IPC.Name.requestOpenHerdrAgent)"))
        #expect(kit.contains("post(IPC.Name.requestOpenHerdrAgent)"))
    }

    @Test func remoteHostsJoinTheAmbientPollEveryTwoMinutes() async throws {
        let fixture = AttentionFixture()
        defer { fixture.close() }
        let clock = AttentionClock(fixture.start)
        let scopes = ScopeLog()
        let job = SessionsJob(
            store: nil, isSubscribed: { false }, defaults: fixture.defaults, notify: { _ in },
            collect: { scope in
                scopes.append(scope)
                return []
            }, now: { clock.now })
        for offset in [0.0, 30, 60, 120, 150] {
            clock.now = fixture.start.addingTimeInterval(offset)
            _ = try await job.run()
        }
        #expect(scopes.names == ["all", "local", "local", "all", "local"])
        for key in [
            AgentSettingsKeys.notifyWhenBlocked, AgentSettingsKeys.notifyWhenFinished,
            AgentSettingsKeys.notifyOnErrors,
        ] {
            fixture.defaults.set(false, forKey: key)
        }
        #expect(try await job.run() == nil)
        #expect(scopes.names.count == 5)
    }
}

private final class AttentionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class ScopeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var names: [String] { lock.withLock { stored } }

    func append(_ scope: HerdrCollectScope) {
        let name =
            switch scope {
            case .all: "all"
            case .local: "local"
            case .machine: "machine"
            }
        lock.withLock { stored.append(name) }
    }
}
