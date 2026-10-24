import Darwin
import Foundation

public actor ClaudeAccountStorage {
    private struct LimitsCleanup: Codable {
        let accountID: UUID
        let profileID: UUID
        var isConnecting: Bool
    }

    private struct LimitsConnection {
        let id: UUID
        let task: Task<ClaudeAccountsState, Error>
    }

    public nonisolated let directory: URL
    private var connectingLimits: [UUID: LimitsConnection] = [:]

    public init(directory: URL) { self.directory = directory }

    public static var defaultDirectory: URL { directory(support: DataRoot.support) }

    public static func directory(support: URL) -> URL {
        support.appendingPathComponent("Accounts", isDirectory: true)
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
            guard
                state.accounts.allSatisfy({ account in
                    previous.accounts.first(where: { $0.id == account.id })?.limitsProfileID
                        == account.limitsProfileID
                })
            else {
                throw ClaudeAccountError.rejected(
                    "Connect subscription limits to change its login.")
            }
            try writeState(state, root: root)
        }
    }

    public func connectLimitsLogin(
        account: ClaudeAccount, newProfileID: UUID = UUID(),
        startLogin: @escaping @Sendable (UUID, URL) async throws -> Void,
        eraseScopedSecret: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> ClaudeAccountsState {
        try await registerLimitsLogin(
            account: account, profileID: newProfileID, createsProfile: true,
            startLogin: startLogin, eraseScopedSecret: eraseScopedSecret)
    }

    private func registerLimitsLogin(
        account: ClaudeAccount, profileID: UUID, createsProfile: Bool,
        startLogin: @escaping @Sendable (UUID, URL) async throws -> Void,
        eraseScopedSecret: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> ClaudeAccountsState {
        guard account.authentication == .oauthToken, !account.isLoggedOut,
            connectingLimits.count < 64, connectingLimits[account.id] == nil
        else { throw ClaudeAccountError.invalidRequest }
        let owner = UUID()
        let task = Task {
            try await self.connectLimitsLoginOwned(
                account: account, id: profileID, createsProfile: createsProfile,
                startLogin: startLogin, eraseScopedSecret: eraseScopedSecret)
        }
        connectingLimits[account.id] = LimitsConnection(id: owner, task: task)
        defer {
            if connectingLimits[account.id]?.id == owner {
                connectingLimits.removeValue(forKey: account.id)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func connectLimitsLoginOwned(
        account: ClaudeAccount, id: UUID, createsProfile: Bool,
        startLogin: @Sendable (UUID, URL) async throws -> Void,
        eraseScopedSecret: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> ClaudeAccountsState {
        let lease = try openLimitsLease()
        defer { flock(lease, LOCK_UN); close(lease) }
        let folder = profileURL(id)
        try withRoot { root in
            try requireSaved(account, root: root)
            var previousCleanup = try readLimitsCleanup(root, state: readState(root))
            if previousCleanup.contains(where: \.isConnecting) {
                for index in previousCleanup.indices { previousCleanup[index].isConnecting = false }
                try writeLimitsCleanup(previousCleanup, root: root)
            }
            if createsProfile {
                let state = try readState(root)
                var cleanup = try readLimitsCleanup(root, state: state)
                guard cleanup.count < 64,
                    !cleanup.contains(where: { $0.accountID == account.id && $0.isConnecting }),
                    !state.accounts.contains(where: { $0.id == id || $0.limitsProfileID == id }),
                    !cleanup.contains(where: { $0.profileID == id })
                else {
                    throw ClaudeAccountError.invalidRequest
                }
                try OwnedAccountFiles.createProfile(id, root: root)
                cleanup.append(
                    LimitsCleanup(accountID: account.id, profileID: id, isConnecting: true))
                do {
                    try writeLimitsCleanup(cleanup, root: root)
                } catch {
                    try OwnedAccountFiles.removeProfile(id, root: root)
                    throw error
                }
            } else {
                guard let descriptor = try OwnedAccountFiles.profile(id, root: root, create: false)
                else { throw ClaudeAccountError.invalidRequest }
                close(descriptor)
                var cleanup = try readLimitsCleanup(root, state: readState(root))
                guard
                    let index = cleanup.firstIndex(where: {
                        $0.accountID == account.id && $0.profileID == id
                    }), !cleanup[index].isConnecting
                else { throw ClaudeAccountError.invalidRequest }
                cleanup[index].isConnecting = true
                try writeLimitsCleanup(cleanup, root: root)
            }
        }
        let result: ClaudeAccountsState
        do {
            try await startLogin(id, folder)
            try await finishLimitsStart(accountID: account.id, id: id)
            try Task.checkCancellation()
            result = try withRoot { root in
                var state = try readState(root)
                guard let index = state.accounts.firstIndex(of: account) else {
                    throw ClaudeAccountError.rejected(
                        "Account settings changed. Reload and try again.")
                }
                guard let descriptor = try OwnedAccountFiles.profile(id, root: root, create: false)
                else { throw ClaudeAccountError.invalidRequest }
                defer { close(descriptor) }
                _ = try OwnedAccountFiles.read(".credentials.json", directory: descriptor)
                state.accounts[index].limitsProfileID = id
                try writeState(state, root: root)
                return state
            }
        } catch {
            let original = error
            do {
                try await finishLimitsStart(accountID: account.id, id: id)
            } catch {
                throw ClaudeLimitsLoginCleanupError(originalError: original, cleanupError: error)
            }
            if createsProfile {
                do {
                    try await Task.detached {
                        guard
                            try await self.pendingLimitsProfile(accountID: account.id, id: id)
                                != nil
                        else { return }
                        try await eraseScopedSecret(folder)
                        try await self.discardLimitsProfile(accountID: account.id, id: id)
                    }.value
                } catch {
                    throw ClaudeLimitsLoginCleanupError(
                        originalError: original, cleanupError: error)
                }
            }
            throw original
        }
        if createsProfile {
            try await Task.detached {
                for retired in try await self.retiredLimitsProfiles(accountID: account.id) {
                    guard
                        let folder = try await self.pendingLimitsProfile(
                            accountID: account.id, id: retired)
                    else { continue }
                    try await eraseScopedSecret(folder)
                    try await self.discardLimitsProfile(accountID: account.id, id: retired)
                }
            }.value
        }
        return result
    }

    private func retiredLimitsProfiles(accountID: UUID) throws -> [UUID] {
        try withRoot(checkCancellation: false) { root in
            let state = try readState(root)
            return try readLimitsCleanup(root, state: state).filter { item in
                item.accountID == accountID && !item.isConnecting
                    && !state.accounts.contains(where: {
                        $0.id == item.profileID || $0.limitsProfileID == item.profileID
                    })
            }.map(\.profileID)
        }
    }

    private func openLimitsLease() throws -> Int32 {
        try Task.checkCancellation()
        let root = try OwnedAccountFiles.root(directory)
        defer { close(root) }
        let descriptor = openat(
            root, ".limits-start.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            0o600)
        guard descriptor >= 0 else { throw ClaudeAccountError.invalidRequest }
        do {
            try OwnedAccountFiles.validate(descriptor, directory: false, privateMode: 0o600)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw ClaudeAccountError.rejected(
                    "Another subscription sign-in is still closing. Try again.")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func finishLimitsStart(accountID: UUID, id: UUID) async throws {
        try await Task.detached {
            try await self.markLimitsStartJoined(accountID: accountID, id: id)
        }.value
    }

    private func markLimitsStartJoined(accountID: UUID, id: UUID) throws {
        try withRoot(checkCancellation: false) { root in
            var cleanup = try readLimitsCleanup(root, state: readState(root))
            guard
                let index = cleanup.firstIndex(where: {
                    $0.accountID == accountID && $0.profileID == id
                })
            else { throw ClaudeAccountError.invalidRequest }
            if cleanup[index].isConnecting {
                cleanup[index].isConnecting = false
                try writeLimitsCleanup(cleanup, root: root)
            }
        }
    }

    public func limitsLoginCredentials(account: ClaudeAccount) throws -> (URL, Data?) {
        try withRoot { root in
            let (id, descriptor) = try limitsProfile(account, root: root)
            defer { close(descriptor) }
            return (
                profileURL(id),
                try OwnedAccountFiles.read(".credentials.json", directory: descriptor)
            )
        }
    }

    public func saveLimitsLoginCredentials(
        account: ClaudeAccount, expected: Data?, data: Data
    ) throws {
        try withRoot { root in
            let (_, descriptor) = try limitsProfile(account, root: root)
            defer { close(descriptor) }
            guard try OwnedAccountFiles.read(".credentials.json", directory: descriptor) == expected
            else {
                throw ClaudeAccountError.rejected(
                    "The subscription login changed. Refresh limits again.")
            }
            try OwnedAccountFiles.write(data, name: ".credentials.json", directory: descriptor)
        }
    }

    public func renewLimitsLogin(
        account: ClaudeAccount, expected: Data?, data: Data,
        writeScopedSecret: @escaping @Sendable (URL, Data) async throws -> Void
    ) async throws {
        guard let profileID = account.limitsProfileID, data.count <= 65_536 else {
            throw ClaudeAccountError.invalidRequest
        }
        _ = try await registerLimitsLogin(
            account: account, profileID: profileID, createsProfile: false,
            startLogin: { _, folder in
                guard try await self.limitsLoginCredentials(account: account).1 == expected else {
                    throw ClaudeAccountError.rejected(
                        "The subscription login changed. Refresh limits again.")
                }
                try await writeScopedSecret(folder, data)
                try Task.checkCancellation()
                try await self.saveLimitsLoginCredentials(
                    account: account, expected: expected, data: data)
            },
            eraseScopedSecret: { _ in throw ClaudeAccountError.invalidRequest })
    }

    private func limitsProfile(_ account: ClaudeAccount, root: Int32) throws -> (UUID, Int32) {
        try requireSaved(account, root: root)
        guard account.authentication == .oauthToken, !account.isLoggedOut,
            let id = account.limitsProfileID,
            let descriptor = try OwnedAccountFiles.profile(id, root: root, create: false)
        else { throw ClaudeAccountError.invalidRequest }
        return (id, descriptor)
    }

    private func pendingLimitsProfile(accountID: UUID, id: UUID) throws -> URL? {
        try withRoot(checkCancellation: false) { root in
            let state = try readState(root)
            let cleanup = try readLimitsCleanup(root, state: state)
            guard cleanup.contains(where: { $0.accountID == accountID && $0.profileID == id })
            else { return nil }
            guard !state.accounts.contains(where: { $0.id == id || $0.limitsProfileID == id })
            else {
                throw ClaudeAccountError.invalidRequest
            }
            if let descriptor = try OwnedAccountFiles.profile(id, root: root, create: false) {
                close(descriptor)
            }
            return profileURL(id)
        }
    }

    private func discardLimitsProfile(accountID: UUID, id: UUID) throws {
        try withRoot(checkCancellation: false) { root in
            let state = try readState(root)
            let cleanup = try readLimitsCleanup(root, state: state)
            guard cleanup.contains(where: { $0.accountID == accountID && $0.profileID == id }),
                !state.accounts.contains(where: { $0.id == id || $0.limitsProfileID == id })
            else { throw ClaudeAccountError.invalidRequest }
            try OwnedAccountFiles.removeProfile(id, root: root)
            try writeLimitsCleanup(
                cleanup.filter { $0.accountID != accountID || $0.profileID != id }, root: root)
        }
    }

    private func readLimitsCleanup(_ root: Int32, state: ClaudeAccountsState) throws
        -> [LimitsCleanup]
    {
        guard
            let data = try OwnedAccountFiles.read(
                "limits-cleanup.json", directory: root, maximum: 16_384)
        else { return [] }
        let cleanup = try JSONDecoder().decode([LimitsCleanup].self, from: data)
        guard cleanup.count <= 64, Set(cleanup.map(\.profileID)).count == cleanup.count,
            cleanup.allSatisfy({ item in
                state.accounts.contains(where: { $0.id == item.accountID })
                    && !state.accounts.contains(where: {
                        $0.id == item.profileID
                            || ($0.id != item.accountID && $0.limitsProfileID == item.profileID)
                    })
            })
        else { throw ClaudeAccountError.invalidRequest }
        return cleanup
    }

    private func writeLimitsCleanup(_ cleanup: [LimitsCleanup], root: Int32) throws {
        let data = try JSONEncoder().encode(cleanup)
        guard cleanup.count <= 64, data.count <= 16_384 else {
            throw ClaudeAccountError.invalidRequest
        }
        try OwnedAccountFiles.write(data, name: "limits-cleanup.json", directory: root)
    }

    private func cleanupProfiles(
        account: ClaudeAccount, root: Int32, eraseScopedSecret: @Sendable (URL) throws -> Void
    ) throws {
        let cleanup = try readLimitsCleanup(root, state: readState(root))
        var visited: Set<UUID> = []
        let profiles =
            [account.id] + [account.limitsProfileID].compactMap { $0 }
            + cleanup.filter { $0.accountID == account.id }.map(\.profileID)
        for id in profiles where visited.insert(id).inserted {
            try eraseScopedSecret(profileURL(id))
            try OwnedAccountFiles.removeProfile(id, root: root)
        }
        if cleanup.contains(where: { $0.accountID == account.id }) {
            try writeLimitsCleanup(cleanup.filter { $0.accountID != account.id }, root: root)
        }
    }

    public func rememberLaunchAccount(_ id: UUID) throws -> ClaudeAccountsState {
        try withRoot { root in
            var state = try readState(root)
            guard state.accounts.contains(where: { $0.id == id }) else {
                throw ClaudeAccountError.rejected(
                    "This account was removed. Choose another account.")
            }
            if state.defaultID != id {
                state.defaultID = id
                try writeState(state, root: root)
            }
            return state
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

    public func logout(
        id: UUID, eraseScopedSecret: @Sendable (URL) throws -> Void
    ) async throws -> ClaudeAccountsState {
        let revoked = try revokeAccount(id)
        await joinLimitsLogin(id)
        let lease = try openLimitsLease()
        defer { flock(lease, LOCK_UN); close(lease) }
        return try withRoot { root in
            var state = try readState(root)
            guard let index = state.accounts.firstIndex(of: revoked) else {
                throw ClaudeAccountError.rejected("Account settings changed. Reload and try again.")
            }
            try cleanupProfiles(
                account: state.accounts[index], root: root, eraseScopedSecret: eraseScopedSecret)
            if state.accounts[index].limitsProfileID != nil {
                state.accounts[index].limitsProfileID = nil
                try writeState(state, root: root)
            }
            return state
        }
    }

    public func forget(
        id: UUID, eraseScopedSecret: @Sendable (URL) throws -> Void
    ) async throws -> ClaudeAccountsState {
        let revoked = try revokeAccount(id)
        await joinLimitsLogin(id)
        let lease = try openLimitsLease()
        defer { flock(lease, LOCK_UN); close(lease) }
        return try withRoot { root in
            var state = try readState(root)
            guard let index = state.accounts.firstIndex(of: revoked) else {
                throw ClaudeAccountError.rejected("Account settings changed. Reload and try again.")
            }
            try cleanupProfiles(
                account: state.accounts[index], root: root, eraseScopedSecret: eraseScopedSecret)
            state.accounts.removeAll { $0.id == id }
            if state.defaultID == id { state.defaultID = nil }
            try writeState(state, root: root)
            return state
        }
    }

    private func revokeAccount(_ id: UUID) throws -> ClaudeAccount {
        try withRoot { root in
            var state = try readState(root)
            guard let index = state.accounts.firstIndex(where: { $0.id == id }) else {
                throw ClaudeAccountError.invalidRequest
            }
            state.accounts[index].credential = ""
            state.accounts[index].loginData = nil
            state.accounts[index].isLoggedOut = true
            try writeState(state, root: root)
            return state.accounts[index]
        }
    }

    private func joinLimitsLogin(_ id: UUID) async {
        guard let connection = connectingLimits[id] else { return }
        connection.task.cancel()
        _ = try? await connection.task.value
        if connectingLimits[id]?.id == connection.id {
            connectingLimits.removeValue(forKey: id)
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
