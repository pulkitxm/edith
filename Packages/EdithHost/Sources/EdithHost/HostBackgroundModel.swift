import EdithExtensionUI
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

    func cancel() {
        generation = UUID()
        actionGeneration = UUID()
        action = nil
        load.cancel()
    }
}
