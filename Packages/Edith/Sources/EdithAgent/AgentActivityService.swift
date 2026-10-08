import EdithKit
import Foundation

public actor AgentActivityService {
    public typealias Settings = @Sendable () -> AgentActivitySettings
    public typealias Listener = @Sendable () async -> Bool
    public typealias Publish = @Sendable (Data) async -> Void

    private struct Pending {
        var request: AgentApprovalRequest
        var eventID: UUID
        var choice: AgentApprovalChoice?
    }

    private let settings: Settings
    private let listener: Listener
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval
    private var sessions: [String: AgentActivitySession] = [:]
    private var pending: [UUID: Pending] = [:]
    private var signals: [String: Date] = [:]
    private var seen: [UUID] = []
    private var seenSet: Set<UUID> = []
    private var previous: AgentActivitySnapshot?
    private var publish: Publish = { _ in }
    private var loop: Task<Void, Never>?
    private var stopped = false

    public init(
        settings: @escaping Settings = { AgentActivitySettings.load() },
        listener: @escaping Listener = { false },
        now: @escaping @Sendable () -> Date = { Date() }, lifetime: TimeInterval = 118
    ) {
        self.settings = settings
        self.listener = listener
        self.now = now
        self.lifetime = min(118, max(1, lifetime))
    }

    public func register(on runtime: AgentRuntime) async {
        let service = AgentActivityService(
            settings: settings, listener: { await runtime.hasSubscribers(topic: .agentActivity) },
            now: now, lifetime: lifetime)
        await runtime.register(operation: AgentActivityOperation.ingest) { payload in
            guard payload.count <= AgentActivityParser.maximumInputBytes else {
                throw AgentError(.refused, "The agent event is too large.")
            }
            let event = try AgentPayload.decode(AgentActivityEvent.self, from: payload)
            return try AgentPayload.encode(await service.ingest(event))
        }
        await runtime.register(operation: AgentActivityOperation.poll) { payload in
            let token = try AgentPayload.decode(AgentApprovalToken.self, from: payload)
            return try AgentPayload.encode(await service.poll(token))
        }
        await runtime.register(operation: AgentActivityOperation.decide) { payload in
            let decision = try AgentPayload.decode(AgentApprovalDecision.self, from: payload)
            return try AgentPayload.encode(await service.decide(decision))
        }
        await runtime.register(operation: AgentActivityOperation.cancel) { payload in
            let token = try AgentPayload.decode(AgentApprovalToken.self, from: payload)
            await service.cancel(token)
            return Data()
        }
        await runtime.registerShutdown(id: "agent.activity") { await service.stop() }
        await service.start { await runtime.publish(topic: .agentActivity, payload: $0) }
    }

    public func start(publish: @escaping Publish) async {
        guard !stopped else { return }
        self.publish = publish
        await tick()
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self.tick()
            }
        }
    }

    public func stop() async {
        stopped = true
        loop?.cancel()
        loop = nil
        pending.removeAll()
        await emit()
    }

    public func ingest(_ proposed: AgentActivityEvent) async -> AgentActivityReceipt {
        guard !stopped, settings().configuration(proposed.provider).observing,
            !proposed.sessionID.isEmpty, proposed.sessionID.utf8.count <= 4096
        else { return AgentActivityReceipt() }
        await reconcile()
        if seenSet.contains(proposed.id) {
            return AgentActivityReceipt(
                request: pending.values.first { $0.eventID == proposed.id }?.request)
        }
        var event = proposed
        event.receivedAt = now()
        remember(event.id)
        signals[event.provider.rawValue] = event.receivedAt
        if var session = sessions[event.identity] {
            session.apply(event)
            sessions[event.identity] = session
        } else {
            sessions[event.identity] = AgentActivitySession(event: event)
        }
        if event.eventName == "permission.replied" {
            pending = pending.filter {
                $0.value.request.sessionID != event.identity
                    || $0.value.request.providerPermissionID != event.permissionID
            }
        } else if event.phase == .ended || event.phase == .finished || event.phase == .error {
            pending = pending.filter { $0.value.request.sessionID != event.identity }
        }
        var request: AgentApprovalRequest?
        if event.permissionRequest, event.tool != nil,
            settings().configuration(event.provider).approvals, pending.count < 64,
            await listener(),
            settings().configuration(event.provider).approvals, !stopped
        {
            if let permissionID = event.permissionID,
                let existing = pending.values.first(where: {
                    $0.request.sessionID == event.identity
                        && $0.request.providerPermissionID == permissionID
                })
            {
                await emit()
                return AgentActivityReceipt(request: existing.request)
            }
            let created = AgentApprovalRequest(event: event, now: now(), lifetime: lifetime)
            pending[created.id] = Pending(request: created, eventID: event.id)
            request = created
        }
        prune()
        await emit()
        return AgentActivityReceipt(request: request)
    }

    public func poll(_ token: AgentApprovalToken) async -> AgentApprovalResult {
        await reconcile()
        guard let item = pending[token.id], item.request.nonce == token.nonce else {
            return AgentApprovalResult()
        }
        guard let choice = item.choice else { return AgentApprovalResult(pending: true) }
        pending[token.id] = nil
        await emit()
        return AgentApprovalResult(choice: choice)
    }

    public func decide(_ decision: AgentApprovalDecision) async -> Bool {
        await reconcile()
        guard var item = pending[decision.token.id], item.request.nonce == decision.token.nonce,
            item.choice == nil, !stopped
        else { return false }
        item.choice = decision.choice
        pending[item.request.id] = item
        await emit()
        return true
    }

    public func cancel(_ token: AgentApprovalToken) async {
        guard pending[token.id]?.request.nonce == token.nonce else { return }
        pending[token.id] = nil
        await emit()
    }

    public func snapshot() -> AgentActivitySnapshot {
        let configuration = settings().normalized()
        let date = now()
        var visible: [AgentActivitySession] = []
        for session in sessions.values where configuration.configuration(session.provider).observing
        {
            var result = session
            if (result.phase == .working || result.phase == .idle),
                date.timeIntervalSince(result.updatedAt) > Double(configuration.quietMinutes * 60)
            {
                result.phase = .quiet
            }
            visible.append(result)
        }
        visible.sort {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
        var requests = pending.values.filter { $0.choice == nil }.map(\.request)
        requests.sort {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
        return AgentActivitySnapshot(
            sessions: visible, approvals: requests, refreshedAt: date,
            settings: configuration, providerSignals: signals)
    }

    public func tick() async {
        await reconcile()
        prune()
        await emit()
    }

    private func reconcile() async {
        let listening = await listener()
        let configuration = settings()
        let date = now()
        pending = pending.filter {
            let provider = configuration.configuration($0.value.request.provider)
            return !stopped && listening && provider.observing && provider.approvals
                && $0.value.request.expiresAt > date
        }
    }

    private func emit() async {
        var next = snapshot()
        next.refreshedAt = previous?.refreshedAt ?? next.refreshedAt
        guard next != previous else { return }
        next.refreshedAt = now()
        previous = next
        if let payload = try? AgentPayload.encode(next) { await publish(payload) }
    }

    private func remember(_ id: UUID) {
        seen.append(id)
        seenSet.insert(id)
        if seen.count > 2048 { seenSet.remove(seen.removeFirst()) }
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-86_400)
        let retained = sessions.values.filter { $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }.prefix(256)
        sessions = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        pending = pending.filter { sessions[$0.value.request.sessionID] != nil }
    }
}
