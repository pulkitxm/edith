import EdithExtensionUI
import EdithHostCore
import Foundation
import Observation

struct HostBackgroundJob: Codable, Equatable, Identifiable, Sendable {
    struct Descriptor: Codable, Equatable, Sendable {
        struct Cadence: Codable, Equatable, Sendable {
            let ambient: Double?
            let live: Double?
        }
        let id: String
        let title: String
        let trigger: String
        let topic: String?
        let cadence: Cadence
        let power: String
        let abilityID: String?
    }
    let descriptor: Descriptor
    let phase: String
    let subscribers: Int
    let lastRun: Date?
    let lastDuration: Double?
    let lastError: String?
    let runCount: Int
    var id: String { descriptor.id }
    var interval: Double? {
        subscribers > 0
            ? descriptor.cadence.live ?? descriptor.cadence.ambient : descriptor.cadence.ambient
    }
    var cadence: String {
        interval.map {
            "Every "
                + Duration.seconds($0).formatted(
                    .units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated))
        } ?? "On demand"
    }
    var canRun: Bool { ["idle", "paused", "failed"].contains(phase) }
}

struct HostBackgroundEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let level: String
    let category: String
    let name: String
    let message: String
    let duration: Double?
    let taskID: UUID?
}

struct HostBackgroundProjection: Sendable {
    let jobs: [HostBackgroundJob]
    let events: [HostBackgroundEvent]
    let unavailable: String?
}

struct HostBackgroundEnvironment {
    let identity: @MainActor () -> String?
    let read: @MainActor () async throws -> HostBackgroundProjection
    let control: @MainActor (String, Bool) async throws -> Void
}

@MainActor @Observable final class HostBackgroundModel {
    private(set) var jobs: [HostBackgroundJob] = []
    private(set) var events: [HostBackgroundEvent] = []
    private(set) var unavailable: String?
    private(set) var failure: String?
    private(set) var action: String?
    let load = ContentLoad()
    @ObservationIgnored private let environment: HostBackgroundEnvironment
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var acceptedIdentity: String?
    @ObservationIgnored private var actionGeneration = UUID()

    init(environment: HostBackgroundEnvironment) { self.environment = environment }

    var current: Bool { acceptedIdentity != nil && acceptedIdentity == environment.identity() }

    func refresh() async {
        let token = UUID()
        generation = token
        let request = load.begin()
        guard let identity = environment.identity() else {
            jobs = []; events = []; acceptedIdentity = nil
            unavailable = "The background service is offline."
            load.complete(request)
            return
        }
        do {
            let projection = try await environment.read()
            try Task.checkCancellation()
            guard generation == token, environment.identity() == identity else {
                if generation == token { load.cancel(request) }
                return
            }
            jobs = projection.jobs
            events = projection.events.sorted { $0.date > $1.date }
            unavailable = projection.unavailable
            acceptedIdentity = identity
            failure = nil
            load.complete(request)
        } catch is CancellationError {
            if generation == token { load.cancel(request) }
        } catch {
            guard generation == token, environment.identity() == identity else {
                if generation == token { load.cancel(request) }
                return
            }
            failure = error.localizedDescription
            load.fail(request, error: error)
        }
    }

    func control(_ job: HostBackgroundJob) async {
        guard current, action == nil, jobs.contains(job), job.phase == "running" || job.canRun,
            let identity = acceptedIdentity
        else { return }
        let token = UUID()
        actionGeneration = token
        action = job.id
        defer { if actionGeneration == token { action = nil } }
        do {
            try Task.checkCancellation()
            try await environment.control(job.id, job.phase == "running")
            try Task.checkCancellation()
            guard actionGeneration == token, environment.identity() == identity else { return }
            await refresh()
        } catch is CancellationError {} catch {
            guard actionGeneration == token, environment.identity() == identity else { return }
            failure = error.localizedDescription
        }
    }

    func lastStatus(for job: HostBackgroundJob) -> String? {
        if let error = job.lastError { return error }
        guard let lastRun = job.lastRun else { return nil }
        return events.first { $0.name == job.id && $0.date >= lastRun && $0.duration != nil }?
            .message
    }

    func cancel() {
        generation = UUID()
        actionGeneration = UUID()
        action = nil
        load.cancel()
    }
}

@MainActor @Observable final class HostBackgroundTimelineModel {
    private(set) var events: [HostBackgroundEvent] = []
    private(set) var visibleCount = 50
    var search = "" { didSet { visibleCount = 50 } }
    var failuresOnly = false { didSet { visibleCount = 50 } }
    var paused = false

    var matches: [HostBackgroundEvent] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            (!failuresOnly || event.level != "info")
                && (query.isEmpty
                    || [event.category, event.name, event.message, event.taskID?.uuidString ?? ""]
                        .contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    var visibleEvents: ArraySlice<HostBackgroundEvent> { matches.prefix(visibleCount) }
    var hasMore: Bool { visibleCount < matches.count }
    var text: String {
        matches.reversed().map { event in
            let task = event.taskID.map { " [task \($0.uuidString)]" } ?? ""
            return
                "\(event.date.ISO8601Format()) [\(event.level)] \(event.category).\(event.name)\(task): \(event.message)"
        }.joined(separator: "\n")
    }

    func receive(_ value: [HostBackgroundEvent]) {
        guard !paused else { return }
        events = Array(value.sorted { $0.date > $1.date }.prefix(500))
    }
    func loadMore() { visibleCount = min(matches.count, visibleCount + 50) }
}

struct HostBackgroundPolicyOwner: Hashable, Sendable {
    let identity: String
    let processIdentifier: Int32
}

struct HostBackgroundPolicyEnvironment {
    let owner: @MainActor () -> HostBackgroundPolicyOwner?
    let read: @MainActor () async throws -> HostCoreBackgroundPolicy
    let set: @MainActor (Bool) async throws -> HostCoreBackgroundPolicy
}

@MainActor @Observable final class HostBackgroundPolicyModel {
    private(set) var failure: String?
    private(set) var saving = false
    let load = ContentLoad()
    @ObservationIgnored private let environment: HostBackgroundPolicyEnvironment
    @ObservationIgnored private var generation = UUID()
    private var acceptedOwner: HostBackgroundPolicyOwner?
    private var policy: HostCoreBackgroundPolicy?

    init(environment: HostBackgroundPolicyEnvironment) { self.environment = environment }

    var owner: HostBackgroundPolicyOwner? { environment.owner() }
    var current: Bool {
        guard let acceptedOwner, let policy else { return false }
        return owner == acceptedOwner && policy.processIdentifier == acceptedOwner.processIdentifier
    }
    var value: Bool? { current ? policy?.pauseAmbientOnBattery : nil }

    func refresh() async {
        guard !saving, !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        let request = load.begin()
        failure = nil
        guard let owner else {
            invalidate()
            let message = "The background service is offline."
            failure = message
            load.fail(request, message: message, offline: true)
            return
        }
        do {
            try Task.checkCancellation()
            let returned = try await environment.read()
            try Task.checkCancellation()
            guard generation == token, self.owner == owner else {
                if generation == token { invalidate(); load.cancel(request) }
                return
            }
            try accept(returned, owner: owner)
            load.complete(request)
        } catch is CancellationError {
            if generation == token { load.cancel(request) }
        } catch {
            guard generation == token, self.owner == owner else {
                if generation == token { invalidate(); load.cancel(request) }
                return
            }
            invalidate()
            failure = error.localizedDescription
            load.fail(request, error: error)
        }
    }

    func set(_ value: Bool) async {
        guard !Task.isCancelled, current, !saving, !load.isRunning, let acceptedOwner else {
            return
        }
        let token = UUID()
        generation = token
        saving = true
        failure = nil
        defer { if generation == token { saving = false } }
        do {
            try Task.checkCancellation()
            let returned = try await environment.set(value)
            try Task.checkCancellation()
            guard generation == token, owner == acceptedOwner else {
                if generation == token { invalidate() }
                return
            }
            try accept(returned, owner: acceptedOwner)
        } catch is CancellationError {} catch {
            guard generation == token, owner == acceptedOwner else {
                if generation == token { invalidate() }
                return
            }
            failure = error.localizedDescription
        }
    }

    func cancel() {
        generation = UUID()
        saving = false
        load.cancel()
        invalidate()
        failure = nil
    }

    private func accept(_ returned: HostCoreBackgroundPolicy, owner: HostBackgroundPolicyOwner)
        throws
    {
        guard returned.processIdentifier == owner.processIdentifier else {
            invalidate()
            throw HostCLIError.rejected("The background policy came from a different process.")
        }
        policy = returned
        acceptedOwner = owner
    }

    private func invalidate() {
        acceptedOwner = nil
        policy = nil
    }
}
