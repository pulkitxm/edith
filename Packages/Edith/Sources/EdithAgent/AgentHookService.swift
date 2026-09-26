import EdithKit
import Foundation

public actor AgentHookService {
    public typealias Probe = @Sendable (HerdrAgentHook) async -> HerdrAgentProbe
    public typealias ArmProbe = @Sendable (HerdrAgent) async -> HerdrAgentProbe
    public typealias Send = @Sendable (HerdrAgentHook) async -> HerdrPromptOutcome
    public typealias Publish = @Sendable (Data) async -> Void

    public static let shared = AgentHookService()
    public static let localInterval = Duration.seconds(2)
    public static let remoteInterval: TimeInterval = 10
    public static let maximumMachinesInFlight = 4
    public static let settledLimit = 50
    public static let settledLifetime: TimeInterval = 86_400
    public static let restartedReason = "Edith restarted while sending, so it was not sent again."

    private let url: URL
    private let probe: Probe
    private let armProbe: ArmProbe
    private let send: Send
    private let now: @Sendable () -> Date
    private let interval: Duration
    private var publish: Publish = { _ in }
    private var snapshot: HerdrHooksSnapshot
    private var remoteCheckedAt: [String: Date] = [:]
    private var inFlight: Set<UUID> = []
    private var loop: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    public init(
        url: URL = AppData.supportDir.appendingPathComponent("agent-hooks.json"),
        interval: Duration = AgentHookService.localInterval,
        probe: @escaping Probe = {
            await HerdrAgentPrompt.probe(
                session: $0.session, pane: $0.pane, machineID: $0.machineID,
                local: $0.machineIsLocal)
        },
        armProbe: @escaping ArmProbe = {
            await HerdrAgentPrompt.probe(
                session: $0.session, pane: $0.pane, machineID: $0.machineID,
                local: $0.machineIsLocal)
        },
        send: @escaping Send = {
            await HerdrAgentPrompt.send(
                $0.message, session: $0.session, pane: $0.pane, machineID: $0.machineID,
                local: $0.machineIsLocal)
        },
        publish: @escaping Publish = { _ in },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.url = url
        self.interval = interval
        self.probe = probe
        self.armProbe = armProbe
        self.send = send
        self.publish = publish
        self.now = now
        var loaded =
            (try? Data(contentsOf: url)).flatMap {
                try? AgentPayload.decode(HerdrHooksSnapshot.self, from: $0)
            } ?? HerdrHooksSnapshot()
        let date = now()
        for index in loaded.hooks.indices where loaded.hooks[index].phase == .sending {
            loaded.hooks[index].settle(.skipped, Self.restartedReason, at: date)
        }
        snapshot = loaded
    }

    public func start(publish: @escaping Publish) async {
        self.publish = publish
        do {
            try await commit(snapshot, force: true)
        } catch {
            AgentLog.logger.error(
                "agent hooks not saved: \(error.localizedDescription, privacy: .public)")
        }
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        waiter?.resume()
        waiter = nil
    }

    public func list() -> HerdrHooksSnapshot { snapshot }

    public func arm(_ request: HerdrHookArmRequest) async throws -> HerdrHooksSnapshot {
        guard let message = HerdrAgentPrompt.normalized(request.message) else {
            throw AgentError(.refused, HerdrAgentPromptError.emptyMessage.localizedDescription)
        }
        guard !request.agent.isTerminal else {
            throw AgentError(.refused, "Hooks only work on agents, not terminals.")
        }
        guard case .agent(let observation) = await armProbe(request.agent),
            observation.identity.verified,
            HerdrKind.displayName(for: observation.kind)
                == HerdrKind.displayName(for: request.agent.kind)
        else {
            throw AgentError(.refused, "The agent is no longer available to watch.")
        }
        guard
            !snapshot.hooks.contains(where: {
                $0.agentID == request.agent.id && inFlight.contains($0.id)
            })
        else {
            throw AgentError(.refused, "A message is already being sent to this agent.")
        }
        var next = snapshot
        next.hooks.removeAll { $0.agentID == request.agent.id && !$0.phase.settled }
        next.hooks.append(
            HerdrAgentHook(
                agent: request.agent, message: message, observation: observation,
                schedule: request.schedule, createdAt: now()))
        try await commit(next)
        waiter?.resume()
        waiter = nil
        return snapshot
    }

    public func remove(_ id: UUID) async throws -> HerdrHooksSnapshot {
        guard !inFlight.contains(id) else {
            throw AgentError(.refused, "The message is already being sent.")
        }
        var next = snapshot
        next.hooks.removeAll { $0.id == id }
        try await commit(next)
        return snapshot
    }

    public func tick() async {
        let date = now()
        let armed = snapshot.hooks.filter(\.isArmed)
        let readyForRemote = armed.filter { isDue($0, at: date) && !$0.machineIsLocal }
        let dueRemote = Set(
            readyForRemote.map(\.machineID).filter {
                date.timeIntervalSince(remoteCheckedAt[$0] ?? .distantPast) >= Self.remoteInterval
            })
        for machine in dueRemote { remoteCheckedAt[machine] = date }
        let ready = armed.filter { isDue($0, at: date) }
        let due = ready.filter { $0.machineIsLocal || dueRemote.contains($0.machineID) }
        var pending = Dictionary(grouping: due, by: \.machineID).values[...]
        await withTaskGroup(of: Void.self) { group in
            func startNext() {
                guard let hooks = pending.popFirst() else { return }
                group.addTask {
                    for hook in hooks {
                        let observed = await self.probe(hook)
                        await self.apply(hook.id, observed)
                    }
                }
            }
            for _ in 0..<Self.maximumMachinesInFlight { startNext() }
            while await group.next() != nil { startNext() }
        }
    }

    private func run() async {
        while !Task.isCancelled {
            if snapshot.hooks.contains(where: \.isArmed) {
                await tick()
                try? await Task.sleep(for: interval)
            } else {
                await withCheckedContinuation { waiter = $0 }
            }
        }
    }

    private func apply(_ id: UUID, _ observed: HerdrAgentProbe) async {
        guard let hook = snapshot.hooks.first(where: { $0.id == id && $0.isArmed }) else { return }
        switch HerdrHookEvaluator.evaluate(hook, observed, now: now()) {
        case .keep(let next):
            guard next != hook else { return }
            try? await update(next)
        case .cancel(let reason):
            var next = hook
            next.settle(.cancelled, reason, at: now())
            try? await update(next)
        case .fire(var next):
            next.phase = .sending
            guard (try? await update(next)) != nil,
                snapshot.hooks.contains(where: { $0.id == id && $0.phase == .sending })
            else { return }
            inFlight.insert(id)
            let outcome = await send(next)
            inFlight.remove(id)
            next.settle(outcome.delivered ? .sent : .skipped, outcome.summary, at: now())
            try? await update(next)
        }
    }

    private func update(_ hook: HerdrAgentHook) async throws {
        guard let index = snapshot.hooks.firstIndex(where: { $0.id == hook.id }) else { return }
        var next = snapshot
        next.hooks[index] = hook
        try await commit(next)
    }

    private func commit(_ proposed: HerdrHooksSnapshot, force: Bool = false) async throws {
        let next = pruned(proposed)
        guard force || next != snapshot else { return }
        let data = try AgentPayload.encode(next)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        snapshot = next
        await publish(data)
    }

    private func isDue(_ hook: HerdrAgentHook, at date: Date) -> Bool {
        switch hook.schedule {
        case .whenFinished: true
        case .at(let when): date >= when
        }
    }

    private func pruned(_ proposed: HerdrHooksSnapshot) -> HerdrHooksSnapshot {
        let cutoff = now().addingTimeInterval(-Self.settledLifetime)
        let settled = proposed.hooks.filter {
            $0.phase.settled && ($0.settledAt ?? $0.createdAt) >= cutoff
        }
        .sorted { ($0.settledAt ?? $0.createdAt) > ($1.settledAt ?? $1.createdAt) }
        .prefix(Self.settledLimit)
        let kept = Set(settled.map(\.id))
        return HerdrHooksSnapshot(
            hooks: proposed.hooks.filter { !$0.phase.settled || kept.contains($0.id) })
    }
}
