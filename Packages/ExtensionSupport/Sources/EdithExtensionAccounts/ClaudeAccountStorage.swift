import Darwin
import Foundation

public actor ClaudeAccountStorage {
    public nonisolated let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let owner = environment["EDITH_EXTENSION_ID"], ["herdr", "usage"].contains(owner),
            let namespace = environment["EDITH_APPLICATION_IDENTIFIER"],
            namespace.range(
                of: "^com\\.pulkit\\.edith(?:\\.(?:dev|tests)\\.[A-Za-z0-9_-]{1,160})?$",
                options: .regularExpression) != nil,
            let path = environment["EDITH_EXTENSION_DATA_ROOT"], path.hasPrefix("/"),
            !path.utf8.contains(0)
        else { throw ClaudeAccountError.invalidRequest }
        let data = URL(fileURLWithPath: path, isDirectory: true)
        let parent = data.deletingLastPathComponent()
        let application = parent.deletingLastPathComponent()
        guard data.standardizedFileURL.path == path, data.resolvingSymlinksInPath().path == path,
            data.lastPathComponent == owner, parent.lastPathComponent == "Data",
            environment["EDITH_EXTENSION_STATE_ROOT"]
                == application.appendingPathComponent("ExtensionState").path
        else { throw ClaudeAccountError.invalidRequest }
        return application.appendingPathComponent("Accounts", isDirectory: true)
    }

    public func load() throws -> ClaudeAccountsState {
        try withRoot { try readState($0) }
    }

    public func save(_ state: ClaudeAccountsState, expected: ClaudeAccountsState? = nil) throws {
        try state.validate()
        try withRoot { root in
            let previous = try readState(root)
            guard expected == nil || previous == expected else {
                throw ClaudeAccountError.rejected("Account settings changed. Reload and try again.")
            }
            guard Set(previous.accounts.map(\.id)).isSubset(of: Set(state.accounts.map(\.id)))
            else {
                throw ClaudeAccountError.rejected("Use forget to remove a saved account.")
            }
            try writeState(state, root: root)
        }
    }

    public func profileDirectory(for id: UUID) throws -> URL {
        try withRoot { root in
            guard try readState(root).accounts.contains(where: { $0.id == id }),
                let descriptor = try OwnedAccountFiles.profile(id, root: root, create: true)
            else { throw ClaudeAccountError.invalidRequest }
            close(descriptor)
            return profileURL(id)
        }
    }

    public func seedLogin(account: ClaudeAccount) throws {
        try withRoot { root in
            try requireSaved(account, root: root)
            guard let profile = try OwnedAccountFiles.profile(account.id, root: root, create: true)
            else {
                throw ClaudeAccountError.invalidRequest
            }
            defer { close(profile) }
            try seed(account, profile: profile)
        }
    }

    public func writeLauncher(
        account: ClaudeAccount, makeScript: @Sendable (URL, URL) throws -> Data
    ) throws -> URL {
        try account.validateLaunch()
        return try withRoot { root in
            try requireSaved(account, root: root)
            guard let profile = try OwnedAccountFiles.profile(account.id, root: root, create: true)
            else {
                throw ClaudeAccountError.invalidRequest
            }
            defer { close(profile) }
            let name = "launch-" + UUID().uuidString + ".sh"
            let url = profileURL(account.id).appendingPathComponent(name)
            let script = try makeScript(profileURL(account.id), url)
            try Task.checkCancellation()
            try seed(account, profile: profile)
            try OwnedAccountFiles.write(
                script, name: name, directory: profile, mode: 0o700, exclusive: true)
            if account.isLoggedOut, account.authentication == .browserLogin {
                var state = try readState(root)
                guard let index = state.accounts.firstIndex(where: { $0.id == account.id }) else {
                    unlinkat(profile, name, 0)
                    throw ClaudeAccountError.invalidRequest
                }
                state.accounts[index].isLoggedOut = false
                do { try writeState(state, root: root) } catch {
                    unlinkat(profile, name, 0)
                    throw error
                }
            }
            return url
        }
    }

    public func removeLauncher(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL.path == url.path,
            url.deletingLastPathComponent().deletingLastPathComponent().path == directory.path,
            let id = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent),
            url.deletingLastPathComponent().lastPathComponent == id.uuidString,
            url.lastPathComponent.hasPrefix("launch-"), url.lastPathComponent.hasSuffix(".sh"),
            UUID(uuidString: String(url.lastPathComponent.dropFirst(7).dropLast(3))) != nil
        else { throw ClaudeAccountError.invalidRequest }
        try withRoot(checkCancellation: false) { root in
            guard let profile = try OwnedAccountFiles.profile(id, root: root, create: false) else {
                return
            }
            defer { close(profile) }
            try OwnedAccountFiles.validateExisting(url.lastPathComponent, directory: profile)
            if unlinkat(profile, url.lastPathComponent, 0) != 0, errno != ENOENT {
                throw ClaudeAccountError.invalidRequest
            }
        }
    }

    public func logout(
        id: UUID, eraseScopedSecret: @Sendable (URL) throws -> Void
    ) throws -> ClaudeAccountsState {
        try withRoot { root in
            var state = try readState(root)
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else {
                throw ClaudeAccountError.invalidRequest
            }
            state.accounts[index].credential = ""
            state.accounts[index].loginData = nil
            state.accounts[index].isLoggedOut = true
            try writeState(state, root: root)
            try eraseScopedSecret(profileURL(id))
            try OwnedAccountFiles.removeProfile(id, root: root)
            return state
        }
    }

    public func forget(
        id: UUID, eraseScopedSecret: @Sendable (URL) throws -> Void
    ) throws -> ClaudeAccountsState {
        try withRoot { root in
            var state = try readState(root)
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else {
                throw ClaudeAccountError.invalidRequest
            }
            state.accounts[index].credential = ""
            state.accounts[index].loginData = nil
            state.accounts[index].isLoggedOut = true
            try writeState(state, root: root)
            try eraseScopedSecret(profileURL(id))
            try OwnedAccountFiles.removeProfile(id, root: root)
            state.accounts.removeAll { $0.id == id }
            if state.defaultID == id { state.defaultID = nil }
            try writeState(state, root: root)
            return state
        }
    }

    static func localCredentials(account: ClaudeAccount, directory: URL) throws -> Data? {
        let root = try OwnedAccountFiles.root(directory)
        defer { close(root) }
        guard
            let saved = try OwnedAccountFiles.read(
                "accounts.json", directory: root, maximum: 60_000)
        else {
            throw ClaudeAccountError.invalidRequest
        }
        let state = try JSONDecoder().decode(ClaudeAccountsState.self, from: saved)
        try state.validate()
        guard state.accounts.contains(account), !account.isLoggedOut else {
            throw ClaudeAccountError.invalidRequest
        }
        guard let profile = try OwnedAccountFiles.profile(account.id, root: root, create: false)
        else {
            return nil
        }
        defer { close(profile) }
        return try OwnedAccountFiles.read(".credentials.json", directory: profile)
    }

    private func profileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func requireSaved(_ account: ClaudeAccount, root: Int32) throws {
        guard try readState(root).accounts.contains(account) else {
            throw ClaudeAccountError.invalidRequest
        }
    }

    private func seed(_ account: ClaudeAccount, profile: Int32) throws {
        guard account.authentication == .browserLogin, let loginData = account.loginData else {
            return
        }
        if try OwnedAccountFiles.read(".credentials.json", directory: profile) == nil {
            try OwnedAccountFiles.write(
                Data(loginData.utf8), name: ".credentials.json", directory: profile, exclusive: true
            )
        }
    }

    private func readState(_ root: Int32) throws -> ClaudeAccountsState {
        guard
            let data = try OwnedAccountFiles.read("accounts.json", directory: root, maximum: 60_000)
        else { return .init() }
        let state = try JSONDecoder().decode(ClaudeAccountsState.self, from: data)
        try state.validate()
        return state
    }

    private func writeState(_ state: ClaudeAccountsState, root: Int32) throws {
        try state.validate()
        try OwnedAccountFiles.write(
            JSONEncoder().encode(state), name: "accounts.json", directory: root)
    }

    private func withRoot<T>(checkCancellation: Bool = true, _ operation: (Int32) throws -> T)
        throws -> T
    {
        if checkCancellation { try Task.checkCancellation() }
        let root = try OwnedAccountFiles.root(directory)
        defer { close(root) }
        let lock = openat(
            root, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw ClaudeAccountError.invalidRequest }
        defer { close(lock) }
        try OwnedAccountFiles.validate(lock, directory: false, privateMode: 0o600)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw ClaudeAccountError.rejected("Account storage is busy. Try again.")
        }
        defer { flock(lock, LOCK_UN) }
        if checkCancellation { try Task.checkCancellation() }
        return try operation(root)
    }
}
