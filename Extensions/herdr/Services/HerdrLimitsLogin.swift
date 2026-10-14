import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation

struct HerdrLimitsLoginState: Codable, Equatable {
    enum Phase: String, Codable {
        case connecting
        case connected
        case cancelled
        case failed
    }

    let accountID: UUID
    let ticket: UUID
    var session: OwnedTerminalHandle?
    var phase: Phase
}

@MainActor protocol HerdrLimitsLoginTerminal: AnyObject {
    var handle: OwnedTerminalHandle { get }
    func waitForExit() async throws -> Int32
    func closeAndWait() async
    func execute(_ operation: String, payload: Data) async throws -> Data
}

extension HerdrLimitsLoginTerminal {
    func execute(_ operation: String, payload: Data) async throws -> Data {
        throw ExtensionPeerError.invalidRequest
    }
}

extension OwnedTerminalSession: HerdrLimitsLoginTerminal {
    var handle: OwnedTerminalHandle { descriptor.handle }
    func closeAndWait() async { await stopAndWait() }
}

enum HerdrLimitsLoginLaunch {
    static func prepare(
        account: ClaudeAccount, profileID: UUID, folder: URL, command: String,
        sharedEnvironment: String, inheritedEnvironment: [String: String]
    ) throws -> OwnedTerminalLaunch {
        try account.validateLaunch()
        guard account.authentication == .oauthToken, !account.isLoggedOut,
            profileID != account.id, profileID != account.limitsProfileID,
            folder.isFileURL, folder.path.hasPrefix("/"),
            folder.lastPathComponent == profileID.uuidString
        else { throw ClaudeAccountError.invalidRequest }
        let shared = try HerdrLaunchSettings.environmentAssignments(sharedEnvironment)
        guard !shared.contains(where: { ["HISTFILE", "SAVEHIST"].contains($0.0.uppercased()) })
        else { throw ClaudeAccountError.invalidRequest }
        let profile = ClaudeAccount(
            id: profileID, name: "Subscription login", authentication: .browserLogin)
        let script = try profile.launchCommand(
            command: command, arguments: ["auth", "login"], environment: sharedEnvironment,
            configurationPath: folder.path)
        let reserved: Set<String> = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_BASE_URL",
            "ANTHROPIC_PROFILE", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST",
            "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "HISTFILE", "SAVEHIST",
        ]
        var environment = inheritedEnvironment.filter { !reserved.contains($0.key.uppercased()) }
        environment["HISTFILE"] = "/dev/null"
        environment["SAVEHIST"] = "0"
        return OwnedTerminalLaunch(
            executable: "/bin/zsh",
            arguments: ["-l", "-i", "-c", "unset HISTFILE; SAVEHIST=0; " + script],
            environment: environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value },
            currentDirectory: folder.path, allowsLocalFileLinks: false,
            resetTerminalAfterInterrupt: false)
    }
}

@MainActor final class HerdrLimitsLogin {
    struct Services {
        let create: @MainActor (OwnedTerminalLaunch) async throws -> any HerdrLimitsLoginTerminal
        let eraseScopedSecret: @Sendable (URL) async throws -> Void

        init(
            create:
                @escaping @MainActor (OwnedTerminalLaunch) async throws ->
                any HerdrLimitsLoginTerminal = { try await OwnedTerminalSession(launch: $0) },
            eraseScopedSecret: @escaping @Sendable (URL) async throws -> Void = {
                try ClaudeAccountImport.eraseScopedSecret($0)
            }
        ) {
            self.create = create
            self.eraseScopedSecret = eraseScopedSecret
        }
    }

    private let services: Services
    private var pending: Task<Void, Never>?
    private var current: HerdrLimitsLoginState?
    private var terminal: (ticket: UUID, session: any HerdrLimitsLoginTerminal)?
    private var stopped = false

    init(services: Services = .init()) { self.services = services }

    func begin(
        account: ClaudeAccount, ticket: UUID, storage: ClaudeAccountStorage, command: String,
        sharedEnvironment: String, inheritedEnvironment: [String: String],
        didConnect: @escaping @MainActor () async -> Void = {}
    ) throws -> HerdrLimitsLoginState {
        guard !stopped, pending == nil, current?.ticket != ticket else {
            throw ExtensionPeerError.rejected("A subscription sign-in is already in progress.")
        }
        let profileID = UUID()
        let launch = try HerdrLimitsLoginLaunch.prepare(
            account: account, profileID: profileID,
            folder: storage.directory.appendingPathComponent(profileID.uuidString),
            command: command, sharedEnvironment: sharedEnvironment,
            inheritedEnvironment: inheritedEnvironment)
        let state = HerdrLimitsLoginState(
            accountID: account.id, ticket: ticket, phase: .connecting)
        current = state
        let services = services
        pending = Task {
            do {
                _ = try await storage.connectLimitsLogin(
                    account: account, newProfileID: profileID,
                    startLogin: { id, folder in
                        guard id == profileID, folder.path == launch.currentDirectory else {
                            throw ExtensionPeerError.invalidRequest
                        }
                        try await self.runTerminal(launch, ticket: state.ticket)
                    }, eraseScopedSecret: services.eraseScopedSecret)
                try Task.checkCancellation()
                await didConnect()
                try Task.checkCancellation()
                self.finish(state.ticket, phase: .connected)
            } catch {
                self.finish(
                    state.ticket,
                    phase: Task.isCancelled || error is CancellationError ? .cancelled : .failed)
            }
        }
        return state
    }

    func status(accountID: UUID, ticket: UUID) throws -> HerdrLimitsLoginState {
        guard let current, current.accountID == accountID, current.ticket == ticket else {
            throw ExtensionPeerError.invalidRequest
        }
        return current
    }

    func cancel(accountID: UUID, ticket: UUID) async throws -> HerdrLimitsLoginState {
        _ = try requestCancellation(accountID: accountID, ticket: ticket)
        let task = pending
        await task?.value
        return try status(accountID: accountID, ticket: ticket)
    }

    func cancel(accountID: UUID) async {
        guard current?.accountID == accountID else { return }
        let task = pending
        task?.cancel()
        await task?.value
    }

    func requestCancellation(accountID: UUID, ticket: UUID) throws -> HerdrLimitsLoginState {
        let state = try status(accountID: accountID, ticket: ticket)
        pending?.cancel()
        return state
    }

    func executeTerminal(_ operation: String, payload: Data) async throws -> Data {
        guard let terminal, current?.ticket == terminal.ticket,
            current?.session == terminal.session.handle,
            [
                "herdr.terminal.read", "herdr.terminal.input", "herdr.terminal.resize",
                "herdr.terminal.close",
            ].contains(operation)
        else { throw ExtensionPeerError.invalidRequest }
        return try await terminal.session.execute(operation, payload: payload)
    }

    func cancelPendingWork() { pending?.cancel() }

    func joinPendingWork() async {
        let task = pending
        await task?.value
    }

    func stop() {
        stopped = true
        pending?.cancel()
    }

    func stopAndWait() async {
        stop()
        let task = pending
        await task?.value
    }

    private func finish(_ ticket: UUID, phase: HerdrLimitsLoginState.Phase) {
        guard current?.ticket == ticket else { return }
        current?.phase = phase
        current?.session = nil
        pending = nil
    }

    private func runTerminal(_ launch: OwnedTerminalLaunch, ticket: UUID) async throws {
        let terminal = try await services.create(launch)
        defer {
            if self.terminal?.ticket == ticket { self.terminal = nil }
        }
        let code: Int32
        do {
            try Task.checkCancellation()
            guard !stopped, current?.ticket == ticket,
                terminal.handle.owner == OwnedTerminalSession.owner
            else { throw ExtensionPeerError.invalidRequest }
            current?.session = terminal.handle
            self.terminal = (ticket, terminal)
            code = try await terminal.waitForExit()
        } catch {
            await terminal.closeAndWait()
            throw error
        }
        await terminal.closeAndWait()
        try Task.checkCancellation()
        guard code == 0 else {
            throw ExtensionPeerError.rejected("Subscription sign-in did not finish. Try again.")
        }
    }
}
