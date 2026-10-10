import EdithExtensionSupport
import Foundation

@MainActor struct HomebrewPageClient {
    private let client: HomebrewClient?
    private let engine: ExtensionEngineClient?

    static func local(_ client: HomebrewClient) -> Self { Self(client: client, engine: nil) }
    static func remote(_ engine: ExtensionEngineClient) -> Self {
        Self(client: nil, engine: engine)
    }

    func preferredKind() async throws -> HomebrewPackageKind {
        if client != nil {
            return HomebrewPackageKind(
                rawValue: SharedDefaults.store.string(forKey: AppStorageKeys.Homebrew.defaultKind)
                    ?? "") ?? .formula
        }
        return try await read("homebrew.preference.read", as: HomebrewPackageKind.self)
    }
    func savePreferredKind(_ kind: HomebrewPackageKind) async throws {
        if client != nil {
            SharedDefaults.store.set(kind.rawValue, forKey: AppStorageKeys.Homebrew.defaultKind);
            return
        }
        _ = try await read(
            "homebrew.preference.write", input: ["kind": kind.rawValue],
            as: HomebrewPackageKind.self)
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
        let data: Data
        if [
            "homebrew.status", "homebrew.list", "homebrew.search", "homebrew.install",
            "homebrew.upgrade", "homebrew.uninstall",
        ].contains(command) {
            var values = input; values["operation"] = String(command.dropFirst("homebrew.".count))
            let begin = try await engine.invoke(
                "homebrew.ui.begin", payload: JSONEncoder().encode(values))
            let job = try JSONDecoder().decode(HomebrewUIJobReply.self, from: begin)
            let poll = try JSONEncoder().encode(["token": job.token.uuidString])
            data = try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation()
                    let response = try await engine.invoke("homebrew.ui.poll", payload: poll)
                    let state = try JSONDecoder().decode(HomebrewUIJobReply.self, from: response)
                    guard state.token == job.token else { throw ExtensionPeerError.invalidRequest }
                    if state.complete {
                        if let error = state.error { throw ExtensionPeerError.rejected(error) }
                        guard let result = state.payload else {
                            throw ExtensionPeerError.invalidRequest
                        }
                        return result
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
            } onCancel: {
                Task { @MainActor in
                    _ = try? await engine.invoke("homebrew.ui.cancel", payload: poll)
                }
            }
        } else {
            data = try await engine.invoke(
                command, payload: JSONEncoder().encode(input), timeout: timeout)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
