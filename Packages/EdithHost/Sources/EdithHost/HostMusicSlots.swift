import EdithExtensionSupport
import EdithHostCore
import Foundation
import Observation

struct HostMusicSlotState: Codable, Equatable, Sendable {
    let version: String
    let footer: Bool
    let sidebar: Bool

    static func decode(_ data: Data, version: String) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw HostMusicSlotError.invalidState }
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.version == version, !state.version.isEmpty, state.version.utf8.count <= 128,
            !(state.footer && state.sidebar)
        else { throw HostMusicSlotError.invalidState }
        return state
    }
}

enum HostMusicSlotError: Error { case invalidState }

@MainActor
@Observable
final class HostMusicSlots {
    typealias Invoke = @MainActor (Data) async throws -> Data
    private let invoke: Invoke
    private let namespace: String
    private let minimumInterval: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private var visibleWindows = Set<UUID>()
    private var version: String?
    private var allowed = false
    private var epoch = UUID()
    private var lastRead: ContinuousClock.Instant?
    private var refreshPending = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskID: UUID?
    @ObservationIgnored private var retiring: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    private(set) var state: HostMusicSlotState?
    private(set) var failure: String?

    init(
        namespace: String, minimumInterval: Duration = .milliseconds(500),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        invoke: @escaping Invoke
    ) {
        self.namespace = namespace; self.minimumInterval = minimumInterval
        self.now = now; self.invoke = invoke
    }

    static func live(marketplace: HostMarketplace) -> HostMusicSlots {
        HostMusicSlots(namespace: marketplace.identity.identifier) { payload in
            guard let package = marketplace.installed["music"],
                marketplace.surfaceAvailability.activeIDs.contains("music"),
                marketplace.sessions.versions["music"] == package.version,
                let pid = marketplace.sessions.processIdentifiers["music"]
            else { throw HostWorkerError.rejected }
            let owner = try HostRemoteKernelIdentity.read(pid)
            let endpoint = try ExtensionPeerEndpoint(
                namespace: marketplace.identity.identifier, owner: "music",
                directory: marketplace.identity.root.appendingPathComponent(
                    "ExtensionState/Commands"))
            let response = try await endpoint.invoke(
                "music.ui.hostSlots", payload: payload, timeout: 5)
            try Task.checkCancellation()
            guard owner.isRunning, marketplace.installed["music"] == package,
                marketplace.surfaceAvailability.activeIDs.contains("music"),
                marketplace.sessions.versions["music"] == package.version,
                marketplace.sessions.processIdentifiers["music"] == owner.pid
            else { throw HostWorkerError.rejected }
            return response
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    var footer: Bool { eligible && state?.footer == true }
    var sidebar: Bool { eligible && state?.sidebar == true }
    var isReading: Bool { task != nil }
    var pendingTaskCount: Int { retiring.count + (task == nil ? 0 : 1) }
    private var eligible: Bool { allowed && version != nil && !visibleWindows.isEmpty }

    func synchronize(version: String?, mediaEnabled: Bool, hidden: Bool) {
        let changed = self.version != version
        self.version = version
        allowed = mediaEnabled && !hidden
        if changed { clear(); lastRead = nil }
        if eligible {
            installObserver()
            if changed || state == nil { refresh() }
        } else {
            clear(); removeObserver()
        }
    }

    func setVisible(_ id: UUID, visible: Bool) {
        if visible { visibleWindows.insert(id) } else { visibleWindows.remove(id) }
        if eligible {
            installObserver()
            if state == nil { refresh() }
        } else {
            clear(); removeObserver()
        }
    }

    func invalidate() { refresh(queue: true) }

    func stop() async {
        visibleWindows = []; version = nil; allowed = false
        clear(); removeObserver()
        for pending in Array(retiring.values) { await pending.value }
    }

    private func clear() {
        epoch = UUID()
        if let task, let taskID { retiring[taskID] = task; task.cancel() }
        task = nil; taskID = nil; refreshPending = false
        state = nil; failure = nil
    }

    private func refresh(queue: Bool = false) {
        guard eligible, let version else { return }
        if task != nil {
            if queue { refreshPending = true }
            return
        }
        if !retiring.isEmpty { refreshPending = true; return }
        let currentEpoch = epoch
        let token = UUID()
        taskID = token
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                retiring[token] = nil
                if taskID == token { task = nil; taskID = nil }
                if task == nil, retiring.isEmpty, refreshPending {
                    refreshPending = false
                    refresh()
                }
            }
            do {
                if let lastRead {
                    let elapsed = lastRead.duration(to: now())
                    if elapsed < minimumInterval {
                        try await Task.sleep(for: minimumInterval - elapsed)
                    }
                }
                try Task.checkCancellation()
                guard epoch == currentEpoch, self.version == version, eligible else { return }
                lastRead = now()
                let data = try await invoke(Data("{}".utf8))
                let value = try HostMusicSlotState.decode(data, version: version)
                try Task.checkCancellation()
                guard epoch == currentEpoch, self.version == version, eligible else { return }
                state = value; failure = nil
            } catch {
                guard !Task.isCancelled, epoch == currentEpoch, self.version == version, eligible
                else { return }
                failure = "The Music bar could not refresh."
            }
        }
    }

    private func installObserver() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .init(namespace + ".musicHostSlots"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidate() }
        }
    }
    private func removeObserver() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }
}
