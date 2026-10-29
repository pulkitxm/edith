import EdithExtensionSupport
import ExtensionMarketplace
import Foundation
import Observation

@MainActor
@Observable
public final class HostExtensionSessions {
    public static let enabledExtensionsKey = "enabledExtensions"
    public let ambientPolicyCoordinator = HostAmbientPolicyCoordinator()

    public private(set) var states: [String: HostActivationState] = [:] {
        didSet { didChange() }
    }
    @ObservationIgnored public var ambientPackageSelected: @MainActor (ExtensionPackage) -> Bool = {
        _ in true
    }
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    @ObservationIgnored public var didRequestNavigation:
        @MainActor (HostWorkerNavigationRequest) async throws -> Void = { _ in
            throw HostWorkerError.rejected
        }
    @ObservationIgnored public var didRequestFolderChoice:
        @MainActor (HostWorkerNavigationRequest) async throws -> HostFolderChoiceResult = { _ in
            throw HostWorkerError.rejected
        }
    @ObservationIgnored public var willDisable: @MainActor (String) async throws -> Void = { _ in }
    public private(set) var versions: [String: String] = [:]
    public private(set) var failures: Set<String> = []
    public private(set) var failureReasons: [String: String] = [:]
    @ObservationIgnored public var retryDelays: [Duration] = [
        .seconds(1), .seconds(5), .seconds(30),
    ]
    @ObservationIgnored public var sleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
    public private(set) var pendingDisableIDs: Set<String> {
        didSet {
            defaults.set(pendingDisableIDs.sorted(), forKey: "pendingDisableExtensions")
            didChange()
        }
    }
    public private(set) var pendingRecoveryIDs: Set<String> {
        didSet {
            defaults.set(pendingRecoveryIDs.sorted(), forKey: "pendingStopRecoveryExtensions")
            didChange()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let create: @MainActor (ExtensionPackage) throws -> HostWorker
    @ObservationIgnored private var workers: [String: HostWorker] = [:]
    @ObservationIgnored private var packages: [String: ExtensionPackage] = [:]
    @ObservationIgnored private var retryPackages: [String: ExtensionPackage] = [:]
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryAttempts: [String: Int] = [:]
    @ObservationIgnored private var disableAttempts: [String: Int] = [:]

    public init(
        defaults: UserDefaults, create: @escaping @MainActor (ExtensionPackage) throws -> HostWorker
    ) {
        self.defaults = defaults
        self.create = create
        pendingDisableIDs = Set(defaults.stringArray(forKey: "pendingDisableExtensions") ?? [])
        pendingRecoveryIDs = Set(
            defaults.stringArray(forKey: "pendingStopRecoveryExtensions") ?? [])
        ambientPolicyCoordinator.changed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = try? await synchronizeAmbientPolicy(
                    pauseAmbientOnBattery: defaults.bool(
                        forKey: HostCoreBackgroundPolicy.preferenceKey))
            }
        }
    }

    public var enabledIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.enabledExtensionsKey) ?? [])
    }
    public var automaticallyEnabledIDs: Set<String> {
        enabledIDs.subtracting(pendingDisableIDs).subtracting(pendingRecoveryIDs)
    }
    public var activeIDs: Set<String> {
        Set(states.keys.filter { states[$0] == .active }).subtracting(pendingDisableIDs)
            .subtracting(pendingRecoveryIDs)
    }
    public var processIdentifiers: [String: Int32] {
        workers.compactMapValues(\.processIdentifier)
    }
    public var workerGenerations: [String: UUID] {
        workers.filter { $0.value.processIdentifier != nil }.mapValues(\.generation)
    }

    public func requestDisable(ids: Set<String>) {
        pendingDisableIDs.formUnion(ids.intersection(enabledIDs.union(workers.keys)))
        for id in ids { ambientPolicyCoordinator.release(owner: id) }
        ambientPolicyCoordinator.invalidate()
    }

    public func restore(packages: [String: ExtensionPackage]) async {
        var restores: [Task<Void, Never>] = []
        for id in enabledIDs.union(pendingDisableIDs).union(pendingRecoveryIDs).sorted() {
            guard let package = packages[id] else { states[id] = .notInstalled; continue }
            restores.append(Task { await restore(id: id, package: package) })
        }
        for restore in restores { await restore.value }
    }

    private func restore(id: String, package: ExtensionPackage) async {
        if pendingDisableIDs.contains(id) {
            packages[id] = package
            do { try await disable(id: id) } catch { failures.insert(id) }
        } else if pendingRecoveryIDs.contains(id) {
            packages[id] = package
            do {
                try await stop(id: id, remember: false, reason: .shutdown)
                if enabledIDs.contains(id) { try await enable(package) }
            } catch { failures.insert(id) }
        } else {
            do { try await enable(package) } catch { failures.insert(id) }
        }
    }

    public func enable(_ package: ExtensionPackage) async throws {
        let id = package.id
        guard states[id] != .starting, states[id] != .stopping else {
            throw HostWorkerError.rejected
        }
        do { try await start(package) } catch {
            if failureReasons[id] == nil, states[id] != .starting, states[id] != .stopping {
                failures.insert(id)
                failureReasons[id] = Self.reason(error)
            }
            throw error
        }
    }

    private func start(_ package: ExtensionPackage) async throws {
        let id = package.id
        cancelRetry(id)
        retryPackages[id] = package
        if pendingDisableIDs.contains(id) {
            packages[id] = package
            try await disable(id: id, remember: false)
        } else if pendingRecoveryIDs.contains(id) {
            packages[id] = package
            do { try await stop(id: id, remember: false, reason: .disable) } catch {
                pendingRecoveryIDs.remove(id)
            }
        }
        if let worker = workers[id], worker.ready {
            if worker.configuration.recoveryOnly {
                try await worker.stop()
                workers[id] = nil
            } else {
                pendingDisableIDs.remove(id)
                states[id] = .active
                clearFailure(id)
                retryAttempts[id] = nil
                save(enabledIDs.union([id]))
                return
            }
        }
        if let worker = workers[id] {
            if !worker.isStopped {
                try await worker.stop()
                guard worker.isStopped else { throw HostWorkerError.stillRunning }
            }
            workers[id] = nil
        }
        pendingDisableIDs.remove(id)
        states[id] = .starting
        clearFailure(id)
        do {
            let worker = try package.admitting(
                hostABI: HostContract.compatibility, architecture: "arm64",
                systemVersion: .init(ProcessInfo.processInfo.operatingSystemVersion)
            ) { try create(package) }
            workers[id] = worker
            worker.didExit = { [weak self, weak worker] in
                guard let self, let worker, self.workers[id] === worker else { return }
                self.workers[id] = nil
                self.versions[id] = nil
                self.ambientPolicyCoordinator.release(owner: id)
                self.ambientPolicyCoordinator.invalidate()
                if self.states[id] != .stopping {
                    let wasActive = self.states[id] == .active
                    self.states[id] = .failed
                    self.failures.insert(id)
                    if wasActive {
                        self.failureReasons[id] = "The extension process exited unexpectedly."
                        self.scheduleRetry(id)
                    }
                }
            }
            worker.didRequestNavigation = { [weak self, weak worker] request in
                guard let self, let worker, self.workers[id] === worker,
                    worker.ready, !worker.configuration.recoveryOnly,
                    self.activeIDs.contains(id), self.versions[id] == worker.configuration.version
                else { throw HostWorkerError.rejected }
                try await self.didRequestNavigation(request)
                try Task.checkCancellation()
                guard self.workers[id] === worker, worker.ready,
                    self.activeIDs.contains(id), self.versions[id] == worker.configuration.version
                else { throw HostWorkerError.rejected }
            }
            worker.didRequestFolderChoice = { [weak self, weak worker] request in
                guard let self, let worker, self.workers[id] === worker, worker.ready,
                    !worker.configuration.recoveryOnly, let pid = worker.processIdentifier,
                    self.activeIDs.contains(id), self.versions[id] == worker.configuration.version
                else { throw HostWorkerError.rejected }
                let process = try HostRemoteKernelIdentity.read(pid)
                let result = try await self.didRequestFolderChoice(request)
                try Task.checkCancellation()
                guard self.workers[id] === worker, worker.ready,
                    worker.processIdentifier == process.pid,
                    process.isRunning, self.activeIDs.contains(id),
                    self.versions[id] == worker.configuration.version
                else { throw HostWorkerError.rejected }
                return result
            }
            try await worker.start()
            guard workers[id] === worker, worker.ready else { throw HostWorkerError.exited }
            versions[id] = package.version
            packages[id] = package
            states[id] = .active
            retryAttempts[id] = nil
            save(enabledIDs.union([id]))
            ambientPolicyCoordinator.invalidate()
        } catch {
            if let worker = workers[id] {
                try? await worker.stop()
                if worker.isStopped { workers[id] = nil; versions[id] = nil }
            }
            states[id] = .failed
            failures.insert(id)
            failureReasons[id] = Self.reason(error)
            scheduleRetry(id)
            throw error
        }
    }

    public func retryFailed(packages available: [String: ExtensionPackage]) async {
        for id in states.filter({ $0.value == .failed }).keys.sorted()
        where automaticallyEnabledIDs.contains(id) {
            guard let package = available[id] ?? retryPackages[id] else { continue }
            retryAttempts[id] = 0
            try? await enable(package)
        }
    }

    private static func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func clearFailure(_ id: String) {
        failures.remove(id)
        failureReasons[id] = nil
    }

    private func cancelRetry(_ id: String) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
    }

    private func scheduleRetry(_ id: String) {
        let attempt = retryAttempts[id] ?? 0
        guard retryTasks[id] == nil, attempt < retryDelays.count,
            automaticallyEnabledIDs.contains(id), retryPackages[id] != nil
        else { return }
        retryAttempts[id] = attempt + 1
        let delay = retryDelays[attempt]
        let sleep = sleep
        retryTasks[id] = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            retryTasks[id] = nil
            guard states[id] == .failed, automaticallyEnabledIDs.contains(id),
                let package = retryPackages[id]
            else { return }
            try? await enable(package)
        }
    }

    private func scheduleDisableRetry(_ id: String) {
        let attempt = disableAttempts[id] ?? 0
        guard retryTasks[id] == nil, attempt < retryDelays.count else { return }
        disableAttempts[id] = attempt + 1
        let delay = retryDelays[attempt]
        let sleep = sleep
        retryTasks[id] = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            retryTasks[id] = nil
            guard states[id] == .failed, pendingDisableIDs.contains(id) else { return }
            try? await disable(id: id)
        }
    }

    public func disable(id: String, remember: Bool = true) async throws {
        try await stop(id: id, remember: remember, reason: .disable)
    }

    private func stop(id: String, remember: Bool, reason: HostWorkerStopReason) async throws {
        guard states[id] != .starting, states[id] != .stopping else {
            throw HostWorkerError.rejected
        }
        cancelRetry(id)
        if remember, enabledIDs.contains(id) || workers[id] != nil { pendingDisableIDs.insert(id) }
        states[id] = .stopping
        ambientPolicyCoordinator.release(owner: id)
        ambientPolicyCoordinator.invalidate()
        do {
            if let worker = workers[id], worker.isStopped,
                worker.requiresRecovery || pendingDisableIDs.contains(id)
                    || pendingRecoveryIDs.contains(id)
            {
                workers[id] = nil
                pendingRecoveryIDs.insert(id)
            }
            try await willDisable(id)
            if let worker = workers[id] { try await worker.prepareStop(reason: reason) }
            if workers[id] == nil, pendingDisableIDs.contains(id) || pendingRecoveryIDs.contains(id)
            {
                guard let package = packages[id] else { throw HostWorkerError.rejected }
                let worker = try package.admitting(
                    hostABI: HostContract.compatibility, architecture: "arm64",
                    systemVersion: .init(ProcessInfo.processInfo.operatingSystemVersion)
                ) { try create(package) }
                workers[id] = worker
                try await worker.start(recoveryOnly: true)
            }
            if let worker = workers[id] { try await worker.stop(reason: reason) }
        } catch {
            if !pendingDisableIDs.contains(id) { pendingRecoveryIDs.insert(id) }
            states[id] = .failed
            failures.insert(id)
            if reason == .disable, remember, error as? HostWorkerError == .timedOut {
                scheduleDisableRetry(id)
            }
            throw error
        }
        disableAttempts[id] = nil
        if remember || pendingDisableIDs.contains(id) { save(enabledIDs.subtracting([id])) }
        pendingDisableIDs.remove(id)
        pendingRecoveryIDs.remove(id)
        workers[id] = nil
        packages[id] = nil
        versions[id] = nil
        states[id] = .disabled
        clearFailure(id)
        retryAttempts[id] = nil
        retryPackages[id] = nil
    }

    public func show(id: String) async throws {
        guard let worker = workers[id], worker.ready else { throw HostWorkerError.rejected }
        try await worker.show()
    }

    public func synchronizeAppearance(identity: HostIdentity) async {
        let pause = defaults.bool(forKey: HostCoreBackgroundPolicy.preferenceKey)
        for (id, worker) in workers where worker.ready {
            do {
                let owner = ambientPolicyOwners().first { $0.id == id }
                let policy: HostAmbientPolicy
                if let owner {
                    try validateAmbientOwner(owner, worker: worker)
                    policy = ambientPolicyCoordinator.policy(
                        owner: owner, pauseAmbientOnBattery: pause)
                } else {
                    guard HostAmbientPolicy.jobs[id] == nil else { continue }
                    policy = .initial(owner: id, pauseAmbientOnBattery: pause)
                }
                try await worker.synchronize(
                    configuration: HostWorkerConfiguration(
                        identity: identity, extensionID: id, version: worker.configuration.version,
                        publicLauncher: worker.configuration.publicLauncher, ambientPolicy: policy))
                if let owner { try validateAmbientOwner(owner, worker: worker) }
            } catch {}
        }
        _ = try? await synchronizeAmbientPolicy(pauseAmbientOnBattery: pause)
    }

    public func ambientPolicyOwners() -> [HostAmbientPolicyOwner] {
        activeIDs.intersection(HostAmbientPolicy.jobs.keys).sorted().map { id in
            let worker = workers[id]
            let pid = worker?.processIdentifier ?? 0
            let kernel = try? HostRemoteKernelIdentity.read(pid)
            return .init(
                id: id, version: versions[id] ?? "", processIdentifier: pid,
                processGeneration: kernel?.generation ?? "")
        }
    }

    public func synchronizeAmbientPolicy(pauseAmbientOnBattery: Bool) async throws
        -> HostAmbientPolicyReceipt
    {
        try await ambientPolicyCoordinator.synchronize(
            pauseAmbientOnBattery: pauseAmbientOnBattery,
            owners: { self.ambientPolicyOwners() },
            apply: { owner, policy in
                guard let worker = self.workers[owner.id] else { throw HostWorkerError.rejected }
                try self.validateAmbientOwner(owner, worker: worker)
                try await worker.synchronizeAmbientPolicy(
                    configuration: worker.configuration.replacingAmbientPolicy(policy))
                try Task.checkCancellation()
                try self.validateAmbientOwner(owner, worker: worker)
            })
    }

    private func validateAmbientOwner(_ owner: HostAmbientPolicyOwner, worker: HostWorker) throws {
        guard workers[owner.id] === worker, worker.ready, !worker.configuration.recoveryOnly,
            activeIDs.contains(owner.id), versions[owner.id] == owner.version,
            let package = packages[owner.id], package.version == owner.version,
            ambientPackageSelected(package),
            worker.configuration.version == owner.version,
            worker.processIdentifier == owner.processIdentifier,
            try HostRemoteKernelIdentity.read(owner.processIdentifier).generation
                == owner.processGeneration
        else { throw HostWorkerError.rejected }
    }

    public func preventsQuit() async -> Bool {
        for worker in Array(workers.values) where await worker.preventsQuit() { return true }
        return false
    }

    public func applyUpdate(_ package: ExtensionPackage) async throws {
        guard !pendingDisableIDs.contains(package.id), states[package.id] == .active,
            versions[package.id] != package.version
        else { return }
        let previous = packages[package.id]
        try await stop(id: package.id, remember: false, reason: .update)
        do { try await enable(package) } catch {
            if let previous { try? await enable(previous) }
            throw error
        }
    }

    @discardableResult public func shutdown(reason: HostWorkerStopReason = .shutdown) async -> Bool
    {
        var completed = true
        for id in Array(retryTasks.keys) { cancelRetry(id) }
        let ids = Set(workers.keys).union(pendingDisableIDs).union(pendingRecoveryIDs)
        if reason == .applicationQuit {
            let stops = ids.map { id in
                Task {
                    do { try await stop(id: id, remember: false, reason: reason) } catch {
                        failures.insert(id)
                        return false
                    }
                    return true
                }
            }
            for stop in stops where !(await stop.value) { completed = false }
        } else {
            for id in ids {
                do { try await stop(id: id, remember: false, reason: reason) } catch {
                    completed = false
                    failures.insert(id)
                }
            }
        }
        return completed && workers.isEmpty
    }

    private func save(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Self.enabledExtensionsKey)
    }
}
