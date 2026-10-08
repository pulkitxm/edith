import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

private final class ActivityEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var configuration = AgentActivitySettings(
        providers: Dictionary(
            uniqueKeysWithValues: AgentActivityProvider.allCases.map {
                ($0.rawValue, AgentActivityProviderSettings(observing: true, approvals: true))
            }))
    private var listening = true
    var now: Date { lock.withLock { date } }
    var settings: AgentActivitySettings { lock.withLock { configuration } }
    var listener: Bool { lock.withLock { listening } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    func setListening(_ value: Bool) { lock.withLock { listening = value } }
    func configure(
        _ value: AgentActivityProviderSettings, provider: AgentActivityProvider = .claude
    ) {
        lock.withLock { configuration.providers[provider.rawValue] = value }
    }
    func service() -> AgentActivityService {
        AgentActivityService(
            settings: { self.settings }, listener: { self.listener }, now: { self.now })
    }
}

private func permissionEvent(provider: AgentActivityProvider = .claude) -> AgentActivityEvent {
    var event = AgentActivityEvent(
        provider: provider, sessionID: "session-1", eventName: "PermissionRequest",
        phase: .permission, project: "/tmp/sample-project")
    event.permissionRequest = true
    event.tool = "Bash"
    event.detail = "swift test"
    event.permissionID = provider == .opencode ? "request-1" : nil
    return event
}

private actor ActivityPublications {
    var values: [AgentActivitySnapshot] = []
    func append(_ data: Data) throws {
        values.append(try AgentPayload.decode(AgentActivitySnapshot.self, from: data))
    }
}

@Suite struct AgentActivityParserTests {
    @Test(arguments: [AgentActivityProvider.claude, .codex])
    func actualPermissionsIncludeExactToolInput(_ provider: AgentActivityProvider) throws {
        let data = Data(
            #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/tmp/demo","tool_name":"Bash","tool_input":{"command":"swift test"}}"#
                .utf8)
        let event = try #require(
            try AgentActivityParser.parse(data, provider: provider, pane: "%7"))
        #expect(event.permissionRequest)
        #expect(event.phase == .permission)
        #expect(event.detail == "swift test")
        #expect(event.pane == "%7")
        #expect(event.permissionID == nil)
    }

    @Test func notificationCannotBecomeAnApprovalRequest() throws {
        let data = Data(
            #"{"hook_event_name":"Notification","session_id":"s1","notification_type":"permission_prompt","message":"Please approve"}"#
                .utf8)
        let event = try #require(try AgentActivityParser.parse(data, provider: .claude))
        #expect(event.phase == .permission)
        #expect(!event.permissionRequest)
        let incomplete = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1"}"#.utf8)
        #expect(
            try AgentActivityParser.parse(incomplete, provider: .claude)?.permissionRequest == false
        )
    }

    @Test func childEventsKeepParentSeparate() throws {
        let data = Data(
            #"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"child","cwd":"/tmp/demo"}"#
                .utf8)
        let event = try #require(try AgentActivityParser.parse(data, provider: .claude))
        let session = AgentActivitySession(event: event)
        #expect(session.id == "claude:child")
        #expect(session.parentID == "claude:parent")
        #expect(session.isSubagent)
        let missing = Data(#"{"hook_event_name":"SubagentStart","session_id":"parent"}"#.utf8)
        #expect(try AgentActivityParser.parse(missing, provider: .claude) == nil)
    }

    @Test func openCodeUsesItsNativeRequestIdentity() throws {
        let data = Data(
            #"{"type":"permission.asked","directory":"/tmp/demo","properties":{"id":"req-1","sessionID":"s1","permission":"bash","patterns":["swift test"],"metadata":{"command":"swift test"}}}"#
                .utf8)
        let event = try #require(try AgentActivityParser.parse(data, provider: .opencode))
        #expect(event.permissionID == "req-1")
        #expect(event.permissionRequest)
        #expect(event.detail == "swift test")
        let replied = Data(
            #"{"type":"permission.replied","properties":{"requestID":"req-1","sessionID":"s1","reply":"once"}}"#
                .utf8)
        #expect(
            try AgentActivityParser.parse(replied, provider: .opencode)?.permissionID == "req-1")
    }

    @Test func unknownMalformedAndOversizedInputCannotProduceEvents() throws {
        #expect(
            try AgentActivityParser.parse(
                Data(#"{"hook_event_name":"Unknown","session_id":"s"}"#.utf8), provider: .codex)
                == nil)
        #expect(
            try AgentActivityParser.parse(Data(repeating: 32, count: 131_073), provider: .codex)
                == nil)
        #expect(throws: (any Error).self) {
            try AgentActivityParser.parse(Data("{".utf8), provider: .claude)
        }
    }

    @Test func sessionRejectsOlderAndOtherProviderEvents() {
        var first = permissionEvent()
        first.receivedAt = Date(timeIntervalSince1970: 100)
        var session = AgentActivitySession(event: first)
        var older = first
        older.receivedAt = Date(timeIntervalSince1970: 99)
        older.phase = .finished
        session.apply(older)
        #expect(session.phase == .permission)
        var other = first
        other.provider = .codex
        other.phase = .finished
        session.apply(other)
        #expect(session.phase == .permission)
    }

    @Test(arguments: AgentActivityProvider.allCases)
    func hookOutputOnlyGrantsOneUse(_ provider: AgentActivityProvider) throws {
        let allow = try AgentActivityHookOutput.data(provider: provider, choice: .allowOnce)
        let object = try #require(JSONSerialization.jsonObject(with: allow) as? [String: Any])
        if provider == .opencode {
            #expect(object["choice"] as? String == "allowOnce")
        } else {
            let hook = try #require(object["hookSpecificOutput"] as? [String: Any])
            let decision = try #require(hook["decision"] as? [String: Any])
            #expect(hook["hookEventName"] as? String == "PermissionRequest")
            #expect(decision["behavior"] as? String == "allow")
            #expect(decision["updatedPermissions"] == nil)
        }
        #expect(
            String(
                data: try AgentActivityHookOutput.data(provider: provider, choice: nil),
                encoding: .utf8) == "{}")
    }
}

@Suite struct AgentActivityServiceTests {
    @Test func approvalsRequireObservationExplicitOptInAndAVisibleClient() async {
        let environment = ActivityEnvironment()
        let service = environment.service()
        environment.setListening(false)
        #expect(await service.ingest(permissionEvent()).token == nil)
        environment.setListening(true)
        environment.configure(AgentActivityProviderSettings(observing: true, approvals: false))
        #expect(await service.ingest(permissionEvent()).token == nil)
        environment.configure(AgentActivityProviderSettings(observing: false, approvals: true))
        #expect(await service.ingest(permissionEvent()).token == nil)
        #expect(await service.snapshot().sessions.isEmpty)
    }

    @Test func approvalIsBoundToNonceAndConsumedOnlyOnce() async throws {
        let service = ActivityEnvironment().service()
        let token = try #require(await service.ingest(permissionEvent()).token)
        let forged = AgentApprovalToken(id: token.id, nonce: UUID())
        #expect(!(await service.decide(AgentApprovalDecision(token: forged, choice: .allowOnce))))
        #expect(await service.poll(forged) == AgentApprovalResult())
        #expect(await service.poll(token).pending)
        #expect(await service.decide(AgentApprovalDecision(token: token, choice: .deny)))
        #expect(!(await service.decide(AgentApprovalDecision(token: token, choice: .allowOnce))))
        #expect(await service.snapshot().approvals.isEmpty)
        #expect(await service.poll(token) == AgentApprovalResult(choice: .deny))
        #expect(await service.poll(token) == AgentApprovalResult())
    }

    @Test func duplicateDeliveryDoesNotCreateAnotherRequestOrIncrementTools() async throws {
        let service = ActivityEnvironment().service()
        let event = permissionEvent()
        let receipt = await service.ingest(event)
        #expect(await service.ingest(event) == receipt)
        #expect(await service.snapshot().approvals.count == 1)
        var tool = event
        tool.id = UUID()
        tool.eventName = "PostToolUse"
        tool.phase = .working
        tool.permissionRequest = false
        _ = await service.ingest(tool)
        _ = await service.ingest(tool)
        #expect(await service.snapshot().sessions.first?.completedTools == 1)
    }

    @Test func expiryFallsBackWithoutGrantingPermission() async throws {
        let environment = ActivityEnvironment()
        let service = environment.service()
        let token = try #require(await service.ingest(permissionEvent()).token)
        environment.advance(119)
        #expect(await service.poll(token) == AgentApprovalResult())
        #expect(!(await service.decide(AgentApprovalDecision(token: token, choice: .allowOnce))))
        #expect(await service.snapshot().approvals.isEmpty)
    }

    @Test func disablingApprovalsOrClosingTheClientCancelsPendingWork() async throws {
        let environment = ActivityEnvironment()
        let service = environment.service()
        let first = try #require(await service.ingest(permissionEvent()).token)
        environment.configure(AgentActivityProviderSettings(observing: true, approvals: false))
        #expect(await service.poll(first) == AgentApprovalResult())
        environment.configure(AgentActivityProviderSettings(observing: true, approvals: true))
        let second = try #require(await service.ingest(permissionEvent()).token)
        environment.setListening(false)
        #expect(await service.poll(second) == AgentApprovalResult())
    }

    @Test func nativeApprovalWinsAndOnlyCancelsItsExactRequest() async throws {
        let service = ActivityEnvironment().service()
        let event = permissionEvent(provider: .opencode)
        let token = try #require(await service.ingest(event).token)
        var replied = event
        replied.id = UUID()
        replied.eventName = "permission.replied"
        replied.permissionRequest = false
        replied.phase = .working
        replied.permissionID = "other-request"
        _ = await service.ingest(replied)
        #expect(await service.poll(token).pending)
        replied.id = UUID()
        replied.permissionID = "request-1"
        _ = await service.ingest(replied)
        #expect(await service.poll(token) == AgentApprovalResult())
    }

    @Test func stopAndExplicitCancellationCannotLeaveApprovalsLive() async throws {
        let service = ActivityEnvironment().service()
        let first = try #require(await service.ingest(permissionEvent()).token)
        await service.cancel(AgentApprovalToken(id: first.id, nonce: UUID()))
        #expect(await service.poll(first).pending)
        await service.cancel(first)
        #expect(await service.poll(first) == AgentApprovalResult())
        let second = try #require(await service.ingest(permissionEvent()).token)
        await service.stop()
        #expect(await service.poll(second) == AgentApprovalResult())
        #expect(await service.ingest(permissionEvent()).token == nil)
    }

    @Test func quietSignalsDoNotClaimAnAgentIsStuckAndNewEventsRestoreItsState() async {
        let environment = ActivityEnvironment()
        let service = environment.service()
        var event = permissionEvent()
        event.phase = .working
        event.permissionRequest = false
        _ = await service.ingest(event)
        environment.advance(601)
        #expect(await service.snapshot().sessions.first?.phase == .quiet)
        event.id = UUID()
        _ = await service.ingest(event)
        #expect(await service.snapshot().sessions.first?.phase == .working)
    }

    @Test func asynchronousObserverDeliveryCannotReopenAFinishedSession() async {
        let environment = ActivityEnvironment()
        let service = environment.service()
        var finished = permissionEvent()
        finished.receivedAt = environment.now
        finished.eventName = "Stop"
        finished.phase = .finished
        finished.permissionRequest = false
        _ = await service.ingest(finished)
        var older = permissionEvent()
        older.receivedAt = environment.now.addingTimeInterval(-1)
        #expect(await service.ingest(older).token == nil)
        #expect(await service.snapshot().sessions.first?.phase == .finished)
    }

    @Test func simultaneousToolRequestsStayIndependentWithinOneSession() async throws {
        let service = ActivityEnvironment().service()
        let first = try #require(await service.ingest(permissionEvent()).token)
        let second = try #require(await service.ingest(permissionEvent()).token)
        #expect(first.id != second.id)
        #expect(await service.snapshot().approvals.count == 2)
        #expect(await service.decide(AgentApprovalDecision(token: first, choice: .allowOnce)))
        #expect(await service.poll(first).choice == .allowOnce)
        #expect(await service.poll(second).pending)
        await service.cancel(second)
    }

    @Test func unchangedTicksDoNotPublishClockNoise() async throws {
        let environment = ActivityEnvironment()
        let service = environment.service()
        let publications = ActivityPublications()
        await service.start { try? await publications.append($0) }
        environment.advance(1)
        await service.tick()
        #expect(await publications.values.count == 1)
        _ = await service.ingest(permissionEvent())
        #expect(await publications.values.count == 2)
        await service.stop()
    }
}
