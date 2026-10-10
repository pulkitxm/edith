import EdithExtensionSupport
import Foundation
import Observation

struct HostNotchCompactOrigin: Equatable, Sendable {
    let identity: HostNotchPanelIdentity
    let displayID: UInt32
    let panelPresentationID: UUID
    let cardPresentationID: UUID
    let tile: SurfaceTile
}

struct HostNotchCompactProvider: Equatable, Sendable {
    let id: String
    let version: String
    var snapshot: SurfaceSnapshot
}

@MainActor
@Observable
final class HostNotchCompactCardModel {
    typealias Admission = @MainActor (HostNotchCompactOrigin) -> [String: String]?
    typealias Navigate = @MainActor (HostNotchCompactOrigin, String, String) async throws -> Void
    let origin: HostNotchCompactOrigin
    private(set) var providers: [HostNotchCompactProvider] = []
    private(set) var loading = false
    private(set) var acting = false
    private(set) var error: String?
    @ObservationIgnored private let requests: SurfaceSnapshotClient
    @ObservationIgnored private let admission: Admission
    @ObservationIgnored private let navigate: Navigate
    @ObservationIgnored private var jobs: [UUID: Task<Void, any Error>] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var stopped = false

    init(
        origin: HostNotchCompactOrigin, requests: SurfaceSnapshotClient,
        admission: @escaping Admission, navigate: @escaping Navigate
    ) {
        self.origin = origin; self.requests = requests
        self.admission = admission; self.navigate = navigate
    }

    nonisolated static func supports(_ widget: SurfaceWidget) -> Bool {
        switch widget {
        case .agents, .focus, .codeStats, .databases, .machines, .github, .desk, .media, .ability:
            true
        default: false
        }
    }

    var admittedVersions: [String: String]? { try? admitted() }

    func requestRefresh() { enqueue { [self] in try await refresh() } }
    func requestAction(providerID: String, actionID: String, value: Double? = nil) {
        enqueue { [self] in
            try await perform(providerID: providerID, actionID: actionID, value: value)
        }
    }
    func requestOpen(providerID: String) {
        enqueue { [self] in try await open(providerID: providerID) }
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !stopped, jobs.count < 4 else { return }
        let token = UUID()
        jobs[token] = Task { [self] in
            defer { jobs[token] = nil }
            do { try await operation() } catch {
                if !(error is CancellationError), !stopped {
                    self.error = "The widget operation did not complete."
                }
            }
        }
    }

    var pendingCount: Int { jobs.count }

    func refresh() async throws {
        let versions = try admitted()
        guard !loading else { return }
        loading = true
        let current = generation
        defer { if generation == current { loading = false } }
        do {
            try await run { [self] in
                var next: [HostNotchCompactProvider] = []
                for id in versions.keys.sorted() {
                    let snapshot = try await requests.snapshot(
                        providerID: id, target: .notch, tile: origin.tile)
                    try validate(versions, generation: current)
                    next.append(.init(id: id, version: versions[id]!, snapshot: snapshot))
                }
                try validate(versions, generation: current)
                providers = next; error = nil
            }
        } catch {
            if generation == current, !(error is CancellationError) {
                self.error = "The widget could not refresh. Retry when its providers are available."
            }
            throw error
        }
    }

    func perform(providerID: String, actionID: String, value: Double? = nil) async throws {
        let versions = try admitted()
        guard !acting, let provider = providers.first(where: { $0.id == providerID }),
            versions[providerID] == provider.version
        else { throw HostNotchPanelError.staleState }
        acting = true
        let current = generation
        defer { if generation == current { acting = false } }
        do {
            try await run { [self] in
                let next = try await requests.perform(
                    providerID: providerID, target: .notch,
                    tile: origin.tile, snapshot: provider.snapshot, actionID: actionID, value: value
                )
                try validate(versions, generation: current)
                guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
                    throw HostNotchPanelError.staleState
                }
                providers[index].snapshot = next; error = nil
            }
        } catch {
            if generation == current, !(error is CancellationError) {
                self.error = "The widget action did not complete."
            }
            throw error
        }
    }

    func open(providerID: String) async throws {
        let versions = try admitted()
        guard let version = versions[providerID] else {
            throw HostNotchPanelError.unavailableProvider
        }
        let current = generation
        try await run { [self] in
            try await navigate(origin, providerID, version)
            try validate(versions, generation: current)
        }
    }

    func invalidate() {
        generation = UUID()
        for task in jobs.values { task.cancel() }
        providers = []; loading = false; acting = false; error = nil
    }

    func stop() async {
        stopped = true
        invalidate()
        for task in Array(jobs.values) { _ = try? await task.value }
    }

    private func admitted() throws -> [String: String] {
        guard !stopped, Self.supports(origin.tile.widget), let versions = admission(origin),
            !versions.isEmpty, versions.keys.allSatisfy(origin.tile.widget.providerIDs.contains),
            versions.values.allSatisfy({ !$0.isEmpty })
        else { throw HostNotchPanelError.unavailableProvider }
        return versions
    }

    private func validate(_ versions: [String: String], generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation, try admitted() == versions else {
            throw HostNotchPanelError.staleState
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard jobs.count < 4 else { throw HostNotchPanelError.capacityExceeded }
        let token = UUID()
        let task = Task { try await operation() }
        jobs[token] = task
        defer { jobs[token] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
