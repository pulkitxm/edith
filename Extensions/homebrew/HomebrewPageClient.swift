import EdithExtensionSupport
import Foundation

@MainActor struct HomebrewPageClient {
    private let client: HomebrewClient?
    private let engine: ExtensionEngineClient?

    static func local(_ client: HomebrewClient) -> Self { Self(client: client, engine: nil) }
    static func remote(_ engine: ExtensionEngineClient) -> Self {
        Self(client: nil, engine: engine)
    }

    func status() async -> HomebrewStatus {
        if let client { return await client.status() }
        return (try? await read("homebrew.status", as: HomebrewStatus.self))
            ?? HomebrewStatus(available: false, executable: nil, version: nil)
    }

    func installed(
        kind: HomebrewPackageKind,
        onInventory: (@Sendable ([HomebrewPackage]) async -> Void)? = nil
    ) async throws -> [HomebrewPackage] {
        if let client { return try await client.installed(kind: kind, onInventory: onInventory) }
        return try await read(
            "homebrew.list", input: ["kind": kind.rawValue], as: [HomebrewPackage].self)
    }

    func search(_ query: String, kind: HomebrewPackageKind) async throws -> [HomebrewPackage] {
        if let client { return try await client.search(query, kind: kind) }
        return try await read(
            "homebrew.search", input: ["query": query, "kind": kind.rawValue],
            as: [HomebrewPackage].self)
    }

    func mutate(_ action: HomebrewMutation, kind: HomebrewPackageKind, name: String) async throws
        -> HomebrewMutationResult
    {
        if let client { return try await client.mutate(action, kind: kind, name: name) }
        return try await read(
            "homebrew." + action.rawValue, input: ["kind": kind.rawValue, "name": name],
            as: HomebrewMutationResult.self, timeout: 30)
    }

    func cached(store: HomebrewListingStore?) async -> HomebrewListingSnapshot? {
        if let store { return await store.load() }
        return try? await read("homebrew.cache", as: HomebrewListingSnapshot?.self)
    }

    private func read<Value: Decodable>(
        _ command: String, input: [String: String] = [:], as type: Value.Type, timeout: Double = 30
    ) async throws -> Value {
        guard let engine else { throw ExtensionPeerError.unavailable }
        let payload = try JSONEncoder().encode(input)
        let data = try await engine.invoke(command, payload: payload, timeout: timeout)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
