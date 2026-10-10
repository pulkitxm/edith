import ExtensionMarketplace
import Foundation
import Observation

@MainActor
@Observable
public final class HostExtensionSessions {
    public static let enabledExtensionsKey = "enabledExtensions"

    public private(set) var states: [String: HostActivationState] = [:] {
        didSet { didChange() }
    }
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    public private(set) var versions: [String: String] = [:]
    public private(set) var failures: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let create: @MainActor (ExtensionPackage) throws -> HostWorker
    @ObservationIgnored private var workers: [String: HostWorker] = [:]
    @ObservationIgnored private var packages: [String: ExtensionPackage] = [:]

    public init(
        defaults: UserDefaults, create: @escaping @MainActor (ExtensionPackage) throws -> HostWorker
    ) {
        self.defaults = defaults
        self.create = create
    }

    public var enabledIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.enabledExtensionsKey) ?? [])
    }
    public var processIdentifiers: [String: Int32] {
        workers.compactMapValues(\.processIdentifier)
    }

    public func restore(packages: [String: ExtensionPackage]) async {
        for id in enabledIDs.sorted() {
            guard let package = packages[id] else { states[id] = .notInstalled; continue }
            do { try await enable(package) } catch { failures.insert(id) }
        }
    }

    public func enable(_ package: ExtensionPackage) async throws {
        let id = package.id
        guard states[id] != .starting, states[id] != .stopping else {
            throw HostWorkerError.rejected
        }
        if workers[id]?.ready == true { return }
        states[id] = .starting
        failures.remove(id)
        do {
            let worker = try create(package)
            workers[id] = worker
            worker.didExit = { [weak self, weak worker] in
                guard let self, let worker, self.workers[id] === worker else { return }
                self.workers[id] = nil
                self.versions[id] = nil
                if self.states[id] != .stopping {
                    self.states[id] = .failed
                    self.failures.insert(id)
                }
            }
            try await worker.start()
            guard workers[id] === worker, worker.ready else { throw HostWorkerError.exited }
            versions[id] = package.version
            packages[id] = package
            states[id] = .active
            save(enabledIDs.union([id]))
        } catch {
            if let worker = workers[id] { try? await worker.stop() }
            workers[id] = nil
            versions[id] = nil
            states[id] = .failed
            failures.insert(id)
            throw error
        }
    }

    public func disable(id: String, remember: Bool = true) async throws {
        guard states[id] != .starting, states[id] != .stopping else {
            throw HostWorkerError.rejected
        }
        states[id] = .stopping
        do {
            if let worker = workers[id] { try await worker.stop() }
        } catch {
            states[id] = workers[id]?.ready == true ? .active : .failed
            failures.insert(id)
            throw error
        }
        if remember { save(enabledIDs.subtracting([id])) }
        workers[id] = nil
        packages[id] = nil
        versions[id] = nil
        states[id] = .disabled
        failures.remove(id)
    }

    public func show(id: String) async throws {
        guard let worker = workers[id], worker.ready else { throw HostWorkerError.rejected }
        try await worker.show()
    }

    public func synchronizeAppearance(identity: HostIdentity) async {
        for (id, worker) in workers where worker.ready {
            try? await worker.synchronize(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: id, version: worker.configuration.version))
        }
    }

    public func applyUpdate(_ package: ExtensionPackage) async throws {
        guard states[package.id] == .active, versions[package.id] != package.version else { return }
        let previous = packages[package.id]
        try await disable(id: package.id, remember: false)
        do { try await enable(package) } catch {
            if let previous { try? await enable(previous) }
            throw error
        }
    }

    @discardableResult public func shutdown() async -> Bool {
        for id in Array(workers.keys) {
            do { try await disable(id: id, remember: false) } catch { failures.insert(id) }
        }
        return workers.isEmpty
    }

    private func save(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Self.enabledExtensionsKey)
    }
}
