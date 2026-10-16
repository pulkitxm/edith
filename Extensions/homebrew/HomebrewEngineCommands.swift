import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor final class HomebrewEngineCommands {
    let uiJobs = HomebrewUIJobs()
    private let cliStreams = try? ExtensionCLIStreams(owner: "homebrew")
    let client: HomebrewClient
    private let defaults: UserDefaults
    private let store: HomebrewListingStore
    private var mutations: [UUID: Task<HomebrewMutationResult, Error>] = [:]
    private var refreshes: [HomebrewPackageKind: HomebrewRefresh] = [:]
    private var snapshot: HomebrewListingSnapshot?
    private var snapshotLoad: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var stopped = false

    init(
        client: HomebrewClient = HomebrewClient(),
        store: HomebrewListingStore = HomebrewListingStore(),
        defaults: UserDefaults = SharedDefaults.store
    ) {
        self.client = client
        self.defaults = defaults
        self.store = store
        snapshotLoad = Task { [weak self] in
            let loaded = await store.load()
            self?.adoptLoaded(loaded)
        }
    }

    private func adoptLoaded(_ loaded: HomebrewListingSnapshot?) {
        if snapshot == nil { snapshot = loaded }
    }

    func cachedSnapshot() async -> HomebrewListingSnapshot? {
        await snapshotLoad?.value
        if snapshot == nil { snapshot = await store.load() }
        return snapshot
    }

    func execute(
        _ command: String, payload: Data,
        onInventory: (@Sendable (Data) async -> Void)? = nil
    ) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if command == "homebrew.cli.catalog" { return try HomebrewCLICatalog.data() }
        if command.hasPrefix("homebrew.cli.stream.") {
            guard let cliStreams else { throw ExtensionPeerError.unavailable }
            return try HomebrewCLIEnvironment.$streamOwner.withValue(self) {
                try cliStreams.invoke(
                    HomebrewCommand.self, operation: command, prefix: "homebrew.cli.stream",
                    payload: payload)
            }
        }
        if command.hasPrefix("homebrew.ui.") {
            return try uiJobs.execute(command, payload: payload, owner: self)
        }
        if command == "homebrew.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await HomebrewCLIExecution.run(request, owner: self))
        }
        let values = try JSONDecoder().decode([String: String].self, from: payload)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch command {
        case "homebrew.preference.read":
            guard values.isEmpty else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(
                HomebrewPackageKind(
                    rawValue: defaults.string(forKey: AppStorageKeys.Homebrew.defaultKind) ?? "")
                    ?? .formula)
        case "homebrew.preference.write":
            guard Set(values.keys) == ["kind"],
                let kind = values["kind"].flatMap(HomebrewPackageKind.init(rawValue:))
            else { throw ExtensionPeerError.invalidRequest }
            defaults.set(kind.rawValue, forKey: AppStorageKeys.Homebrew.defaultKind)
            return try encoder.encode(kind)
        case "homebrew.status":
            guard values.isEmpty else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(await client.status())
        case "homebrew.cache":
            guard values.isEmpty else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(await cachedSnapshot())
        case "homebrew.list":
            guard Set(values.keys).isSubset(of: ["kind"]),
                let kind = values["kind"].flatMap(HomebrewPackageKind.init(rawValue:))
            else { throw ExtensionPeerError.invalidRequest }
            let packages = try await refresh(kind: kind, onInventory: onInventory)
            return try encoder.encode(packages)
        case "homebrew.search":
            guard Set(values.keys) == ["query", "kind"], let query = values["query"],
                let kind = values["kind"].flatMap(HomebrewPackageKind.init(rawValue:))
            else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(try await client.search(query, kind: kind))
        case "homebrew.install", "homebrew.upgrade", "homebrew.uninstall":
            guard Set(values.keys) == ["name", "kind"], let name = values["name"],
                let kind = values["kind"].flatMap(HomebrewPackageKind.init(rawValue:)),
                let action = HomebrewMutation(
                    rawValue: String(command.dropFirst("homebrew.".count)))
            else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(try await mutate(action, kind: kind, name: name))
        case "homebrew.cancel":
            guard values.isEmpty else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(["cancelled": cancel()])
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    func refresh(
        kind: HomebrewPackageKind, onInventory: (@Sendable (Data) async -> Void)?
    ) async throws -> [HomebrewPackage] {
        let refresh: HomebrewRefresh
        if let running = refreshes[kind] {
            refresh = running
        } else {
            refresh = HomebrewRefresh()
            refreshes[kind] = refresh
            refresh.task = Task { [weak self, weak refresh] in
                guard let self, let refresh else { return }
                do {
                    let packages = try await runRefresh(kind: kind, refresh: refresh)
                    refresh.finish(.success(packages))
                } catch {
                    refresh.finish(.failure(error))
                }
                if refreshes[kind] === refresh { refreshes.removeValue(forKey: kind) }
            }
        }
        let observer = UUID()
        if let onInventory { refresh.observers[observer] = onInventory }
        defer { refresh.observers.removeValue(forKey: observer) }
        let packages = try await refresh.wait(observer)
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return packages
    }

    private func runRefresh(kind: HomebrewPackageKind, refresh: HomebrewRefresh) async throws
        -> [HomebrewPackage]
    {
        let status = await client.status()
        let packages = try await client.installed(kind: kind) { [weak self] inventory in
            await self?.publish(inventory, kind: kind, status: status, refresh: refresh)
        }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        var updated = await cachedSnapshot() ?? HomebrewListingSnapshot(status: status)
        updated.status = status
        updated.packages[kind] = packages
        snapshot = updated
        persist(updated)
        await persistence?.value
        return packages
    }

    private func publish(
        _ inventory: [HomebrewPackage], kind: HomebrewPackageKind, status: HomebrewStatus,
        refresh: HomebrewRefresh
    ) async {
        guard !stopped else { return }
        var updated = await cachedSnapshot() ?? HomebrewListingSnapshot(status: status)
        updated.status = status
        updated.packages[kind] = HomebrewPackageListing.preservingOutdatedFlags(
            inventory, from: updated.packages[kind] ?? [])
        snapshot = updated
        persist(updated)
        guard let visible = updated.packages[kind], let data = try? JSONEncoder().encode(visible)
        else { return }
        for observer in Array(refresh.observers.values) { await observer(data) }
    }

    private func persist(_ value: HomebrewListingSnapshot) {
        let previous = persistence
        persistence = Task { [store] in
            await previous?.value
            try? await store.save(value)
        }
    }

    func flushPersistence() async { await persistence?.value }

    func mutate(_ action: HomebrewMutation, kind: HomebrewPackageKind, name: String) async throws
        -> HomebrewMutationResult
    {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let token = UUID()
        let task = Task { try await client.mutate(action, kind: kind, name: name) }
        mutations[token] = task
        defer { mutations.removeValue(forKey: token) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return result
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult func cancel() -> Bool {
        let active = !mutations.isEmpty
        for task in mutations.values { task.cancel() }
        return active
    }

    func shutdown() {
        stopped = true
        cancel()
        for refresh in refreshes.values { refresh.task?.cancel() }
        uiJobs.shutdown()
        cliStreams?.stop()
    }

    func shutdownAndWait() async { await cancelPendingWorkAndWait() }

    func cancelPendingWorkAndWait() async {
        shutdown()
        await uiJobs.shutdownAndWait()
        await cliStreams?.stopAndWait()
        for task in mutations.values { _ = try? await task.value }
        for refresh in Array(refreshes.values) { await refresh.task?.value }
        await snapshotLoad?.value
        await persistence?.value
    }
}

@MainActor final class HomebrewRefresh {
    var observers: [UUID: @Sendable (Data) async -> Void] = [:]
    var task: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<[HomebrewPackage], Error>] = [:]
    private var result: Result<[HomebrewPackage], Error>?

    func wait(_ id: UUID) async throws -> [HomebrewPackage] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.abandon(id) }
        }
    }

    func finish(_ outcome: Result<[HomebrewPackage], Error>) {
        result = outcome
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume(with: outcome) }
    }

    private func abandon(_ id: UUID) {
        observers.removeValue(forKey: id)
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
