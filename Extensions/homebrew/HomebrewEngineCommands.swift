import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor final class HomebrewEngineCommands {
    let uiJobs = HomebrewUIJobs()
    let client: HomebrewClient
    private let store: HomebrewListingStore
    private var mutations: [UUID: Task<HomebrewMutationResult, Error>] = [:]
    private var stopped = false

    init(
        client: HomebrewClient = HomebrewClient(),
        store: HomebrewListingStore = HomebrewListingStore()
    ) {
        self.client = client
        self.store = store
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
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
        case "homebrew.status":
            guard values.isEmpty else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(await client.status())
        case "homebrew.cache":
            guard values.isEmpty else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(await store.load())
        case "homebrew.list":
            guard Set(values.keys).isSubset(of: ["kind"]),
                let kind = values["kind"].flatMap(HomebrewPackageKind.init(rawValue:))
            else { throw ExtensionPeerError.invalidRequest }
            let token = await store.claim()
            let status = await client.status()
            let packages = try await client.installed(kind: kind)
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            var snapshot = await store.load() ?? HomebrewListingSnapshot(status: status)
            snapshot.status = status
            snapshot.packages[kind] = packages
            try await store.save(snapshot, replacing: token)
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

    func shutdown() { stopped = true; cancel(); uiJobs.shutdown() }

    func shutdownAndWait() async {
        shutdown()
        await uiJobs.shutdownAndWait()
        for task in mutations.values { _ = try? await task.value }
    }
}
