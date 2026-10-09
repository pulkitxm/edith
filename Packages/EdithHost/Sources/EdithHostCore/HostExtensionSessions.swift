import ExtensionMarketplace
import Foundation
import Observation

@MainActor
@Observable
public final class HostExtensionSessions {
    public private(set) var states: [String: HostActivationState] = [:]
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
        Set(defaults.stringArray(forKey: "enabledExtensions") ?? [])
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
        if remember { save(enabledIDs.subtracting([id])) }
        states[id] = .stopping
        do {
            if let worker = workers[id] { try await worker.stop() }
        } catch {
            states[id] = .failed
            failures.insert(id)
            throw error
        }
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

    public func applyUpdate(_ package: ExtensionPackage) async throws {
        guard states[package.id] == .active, versions[package.id] != package.version else { return }
        let previous = packages[package.id]
        try await disable(id: package.id, remember: false)
        do { try await enable(package) } catch {
            if let previous { try? await enable(previous) }
            throw error
        }
    }

    public func shutdown() async {
        for (id, worker) in workers {
            states[id] = .stopping
            try? await worker.stop()
            states[id] = .disabled
        }
        workers.removeAll()
        packages.removeAll()
        versions.removeAll()
    }

    private func save(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: "enabledExtensions")
    }
}
