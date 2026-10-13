import Foundation

public actor ClaudeAccountStorage {
    public static var directory: URL { DataRoot.support.appendingPathComponent("herdr/accounts") }
    private let root: URL
    private var file: URL { root.appendingPathComponent("accounts.json") }

    public init(directory: URL = ClaudeAccountStorage.directory) { root = directory }

    public func load() throws -> ClaudeAccountsState {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let state = try JSONDecoder().decode(ClaudeAccountsState.self, from: Data(contentsOf: file))
        try state.validate()
        return state
    }

    public func save(_ state: ClaudeAccountsState) throws {
        try state.validate()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func rememberLaunchAccount(_ id: UUID) throws -> ClaudeAccountsState {
        var state = try load()
        guard state.accounts.contains(where: { $0.id == id }) else { return state }
        state.defaultID = id
        try save(state)
        return state
    }
}
