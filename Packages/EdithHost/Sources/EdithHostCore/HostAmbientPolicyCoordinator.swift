import Foundation
import Observation

public struct HostAmbientPolicy: Codable, Equatable, Sendable {
    public let pauseAmbientOnBattery: Bool
    public let subscribers: [String: Int]

    public init(pauseAmbientOnBattery: Bool, subscribers: [String: Int]) {
        self.pauseAmbientOnBattery = pauseAmbientOnBattery
        self.subscribers = subscribers
    }

    public static let jobs: [String: [String]] = [
        "usage": ["usage.refresh", "usage.limits"], "herdr": ["sessions.discover"],
        "machines": ["machines.health"], "attention": ["attention.ingest"],
        "companion": ["companion.health"], "codeStats": ["codestats.schedule"],
    ]
    public static let liveJobs: Set<String> = [
        "usage.limits", "sessions.discover", "attention.ingest", "companion.health",
    ]

    public static func initial(owner: String, pauseAmbientOnBattery: Bool) -> Self {
        .init(
            pauseAmbientOnBattery: pauseAmbientOnBattery,
            subscribers: Dictionary(uniqueKeysWithValues: (jobs[owner] ?? []).map { ($0, 0) }))
    }

    public func validate(owner: String) throws {
        guard Set(subscribers.keys) == Set(Self.jobs[owner] ?? []),
            subscribers.allSatisfy({
                (0...128).contains($0.value)
                    && (Self.liveJobs.contains($0.key) || $0.value == 0)
            })
        else { throw HostWorkerError.rejected }
    }

    public func context(owner: String) throws -> NSDictionary {
        try validate(owner: owner)
        guard Self.jobs[owner] != nil else { return [:] }
        return [
            "ambientPolicy": [
                "pauseAmbientOnBattery": pauseAmbientOnBattery,
                "subscribers": subscribers,
            ]
        ] as NSDictionary
    }
}

public struct HostAmbientPolicyOwner: Equatable, Sendable {
    public let id: String
    public let version: String
    public let processIdentifier: Int32
    public let processGeneration: String

    public init(id: String, version: String, processIdentifier: Int32, processGeneration: String) {
        self.id = id; self.version = version; self.processIdentifier = processIdentifier
        self.processGeneration = processGeneration
    }
}

public struct HostAmbientPolicyReceipt: Equatable, Sendable {
    public struct Owner: Equatable, Sendable {
        public let identity: HostAmbientPolicyOwner
        public let policy: HostAmbientPolicy
        public let failure: String?
        public var applied: Bool { failure == nil }
        public init(identity: HostAmbientPolicyOwner, policy: HostAmbientPolicy, failure: String?) {
            self.identity = identity; self.policy = policy; self.failure = failure
        }
    }
    public let generation: UUID
    public let pauseAmbientOnBattery: Bool
    public let owners: [Owner]
    public var applied: Bool { owners.allSatisfy(\.applied) }
    public init(generation: UUID, pauseAmbientOnBattery: Bool, owners: [Owner]) {
        self.generation = generation; self.pauseAmbientOnBattery = pauseAmbientOnBattery;
        self.owners = owners
    }
}

@MainActor @Observable public final class HostAmbientPolicyCoordinator {
    private struct Lease {
        let owner: HostAmbientPolicyOwner
        let job: String
    }
    public private(set) var generation = UUID()
    public private(set) var receipt: HostAmbientPolicyReceipt?
    @ObservationIgnored public var changed: @MainActor () -> Void = {}
    @ObservationIgnored private var leases: [UUID: Lease] = [:]
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var flight:
        (
            token: UUID, scalar: Bool, owners: [HostAmbientPolicyOwner],
            task: Task<HostAmbientPolicyReceipt, any Error>
        )?
    private struct SceneRequest {
        let token: UUID
        let owner: HostAmbientPolicyOwner
    }
    @ObservationIgnored private var sceneRequests: [UUID: SceneRequest] = [:]

    public init() {}

    public static func topic(owner: String, location: String, section: String?) -> String? {
        switch (owner, location, section) {
        case ("usage", "main", nil), ("usage", "main", "usage"),
            ("usage", "main", "dashboard"), ("usage", "home", "limits"),
            ("usage", "notch", "limits"):
            return "usage.limits"
        case ("herdr", "main", nil), ("herdr", "main", "herdr"),
            ("herdr", "herdr.agent", "herdr"), ("herdr", "herdr.space", "herdr"):
            return "sessions.discover"
        case ("attention", "main", "attention"):
            return "attention.ingest"
        case ("companion", "main", nil), ("companion", "main", "companion"):
            return "companion.health"
        default: return nil
        }
    }

    public func visible(presentation: UUID, owner: HostAmbientPolicyOwner, job: String) throws {
        guard Self.jobsFor(owner.id).contains(job), HostAmbientPolicy.liveJobs.contains(job) else {
            throw HostWorkerError.rejected
        }
        if let lease = leases[presentation], lease.owner == owner, lease.job == job { return }
        guard leases.values.filter({ $0.owner == owner && $0.job == job }).count < 128 else {
            throw HostWorkerError.rejected
        }
        leases[presentation] = Lease(owner: owner, job: job)
        invalidate()
    }

    public func release(presentation: UUID) {
        sceneRequests[presentation] = nil
        if leases.removeValue(forKey: presentation) != nil { invalidate() }
    }

    public func release(owner: String) {
        sceneRequests = sceneRequests.filter { $0.value.owner.id != owner }
        let previous = leases.count
        leases = leases.filter { $0.value.owner.id != owner }
        if previous != leases.count { invalidate() }
    }

    public func updateScene(
        presentation: UUID, owner: HostAmbientPolicyOwner, job: String, visible: Bool,
        validate: @escaping @MainActor () throws -> Void,
        validatePresented: @escaping @MainActor () throws -> Void,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let token = UUID()
        sceneRequests[presentation] = SceneRequest(token: token, owner: owner)
        if !visible, leases.removeValue(forKey: presentation) != nil { invalidate() }
        do {
            try validate()
            try await operation()
            try Task.checkCancellation()
            guard sceneRequests[presentation]?.token == token else { throw CancellationError() }
            try validatePresented()
            if visible { try self.visible(presentation: presentation, owner: owner, job: job) }
        } catch {
            if sceneRequests[presentation]?.token == token { release(presentation: presentation) }
            throw error
        }
    }

    public func invalidate() {
        generation = UUID()
        receipt = nil
        changed()
    }

    public func current(_ receipt: HostAmbientPolicyReceipt, owners: [HostAmbientPolicyOwner])
        -> Bool
    {
        self.receipt == receipt && receipt.generation == generation
            && receipt.owners.map(\.identity) == owners.sorted { $0.id < $1.id }
    }

    public func synchronize(
        pauseAmbientOnBattery: Bool,
        owners: @escaping @MainActor () throws -> [HostAmbientPolicyOwner],
        apply: @escaping @MainActor (HostAmbientPolicyOwner, HostAmbientPolicy) async throws -> Void
    ) async throws -> HostAmbientPolicyReceipt {
        let requestedOwners = try owners().sorted { $0.id < $1.id }
        if let flight, flight.token == generation, flight.scalar == pauseAmbientOnBattery,
            flight.owners == requestedOwners
        {
            let result = try await flight.task.value
            try Task.checkCancellation()
            return result
        }
        let token = UUID()
        generation = token
        receipt = nil
        let previous = tail
        let flight = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            let selected = try owners().sorted { $0.id < $1.id }
            guard Set(selected.map(\.id)).count == selected.count,
                selected.allSatisfy({ HostAmbientPolicy.jobs[$0.id] != nil })
            else { throw HostWorkerError.rejected }
            var results: [HostAmbientPolicyReceipt.Owner] = []
            for owner in selected {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                let policy = policy(owner: owner, pauseAmbientOnBattery: pauseAmbientOnBattery)
                var failure: String?
                do {
                    guard owner.processIdentifier > 1, !owner.version.isEmpty,
                        !owner.processGeneration.isEmpty, try owners().contains(owner)
                    else { throw HostWorkerError.rejected }
                    try await apply(owner, policy)
                    try Task.checkCancellation()
                    guard try owners().contains(owner) else { throw HostWorkerError.rejected }
                } catch is CancellationError { throw CancellationError() } catch {
                    failure = error.localizedDescription
                }
                results.append(.init(identity: owner, policy: policy, failure: failure))
            }
            try Task.checkCancellation()
            guard generation == token, try owners().sorted(by: { $0.id < $1.id }) == selected else {
                throw CancellationError()
            }
            let result = HostAmbientPolicyReceipt(
                generation: token,
                pauseAmbientOnBattery: pauseAmbientOnBattery, owners: results)
            receipt = result
            return result
        }
        self.flight = (token, pauseAmbientOnBattery, requestedOwners, flight)
        tail = Task { _ = try? await flight.value }
        defer { if self.flight?.token == token { self.flight = nil } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await flight.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            flight.cancel()
        }
    }

    private static func jobsFor(_ owner: String) -> [String] { HostAmbientPolicy.jobs[owner] ?? [] }

    private func policy(owner: HostAmbientPolicyOwner, pauseAmbientOnBattery: Bool)
        -> HostAmbientPolicy
    {
        var counts = HostAmbientPolicy.initial(
            owner: owner.id,
            pauseAmbientOnBattery: pauseAmbientOnBattery
        ).subscribers
        for lease in leases.values where lease.owner == owner {
            counts[lease.job, default: 0] += 1
        }
        return .init(pauseAmbientOnBattery: pauseAmbientOnBattery, subscribers: counts)
    }
}

public struct HostBackgroundPolicyResult: Sendable {
    public let core: HostCoreBackgroundPolicy
    public let propagation: HostAmbientPolicyReceipt
    public var processIdentifier: Int32 { core.processIdentifier }
    public var pauseAmbientOnBattery: Bool { core.pauseAmbientOnBattery }

    public init(core: HostCoreBackgroundPolicy, propagation: HostAmbientPolicyReceipt) {
        self.core = core; self.propagation = propagation
    }
    @MainActor public static func checked(
        core: HostCoreBackgroundPolicy,
        validateCore: @MainActor () throws -> Void,
        synchronize: @MainActor (Bool) async throws -> HostAmbientPolicyReceipt,
        recheck: @MainActor () async throws -> HostCoreBackgroundPolicy,
        current: @MainActor (HostAmbientPolicyReceipt) -> Bool
    ) async throws -> Self {
        try Task.checkCancellation()
        try validateCore()
        let propagation = try await synchronize(core.pauseAmbientOnBattery)
        let returned = try await recheck()
        try Task.checkCancellation()
        try validateCore()
        guard core == returned, propagation.pauseAmbientOnBattery == returned.pauseAmbientOnBattery,
            propagation.owners.allSatisfy({
                $0.policy.pauseAmbientOnBattery == returned.pauseAmbientOnBattery
            }),
            current(propagation)
        else { throw HostWorkerError.rejected }
        return .init(core: returned, propagation: propagation)
    }

}
