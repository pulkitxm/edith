import EdithKit
import Foundation
import Observation

@MainActor @Observable final class ClaudeSubscriptionLogin {
    typealias RunTerminal =
        @MainActor (ClaudeSubscriptionLogin, ClaudeLimitsLoginLaunch) async throws -> Int32?

    let holder = TerminalSessionHolder()
    private(set) var accountID: UUID?
    private(set) var running = false
    private(set) var connected = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var exitWaiter: CheckedContinuation<Int32?, Never>?
    @ObservationIgnored private let runTerminal: RunTerminal
    @ObservationIgnored private let eraseScopedSecret: @Sendable (URL) async throws -> Void
    @ObservationIgnored private let inheritedEnvironment: @MainActor () -> [String: String]

    init(
        runTerminal: @escaping RunTerminal = { login, launch in
            try await login.runHeldTerminal(launch)
        },
        eraseScopedSecret: @escaping @Sendable (URL) async throws -> Void = {
            try ClaudeAccountKeychain.eraseScopedSecret($0)
        },
        inheritedEnvironment: @escaping @MainActor () -> [String: String] = {
            var environment = CLIToolEnvironment.sanitized()
            environment["TERM"] = "xterm-256color"
            return environment
        }
    ) {
        self.runTerminal = runTerminal
        self.eraseScopedSecret = eraseScopedSecret
        self.inheritedEnvironment = inheritedEnvironment
    }

    func start(
        accountID: UUID, accounts: ClaudeAccountsModel,
        defaults: UserDefaults = SharedDefaults.store
    ) {
        guard task == nil, !running else {
            error = "Close the current subscription sign-in before starting another."
            return
        }
        self.accountID = accountID
        running = true
        connected = false
        error = nil
        task = Task { [self] in
            do {
                try await connect(accountID: accountID, accounts: accounts, defaults: defaults)
                try Task.checkCancellation()
                connected = true
            } catch {
                if error is ClaudeLimitsLoginCleanupError {
                    self.error = "Subscription sign-in could not be closed. Try cancelling again."
                } else if !Task.isCancelled {
                    self.error = Self.message(error)
                }
            }
            finishTerminal(nil)
            holder.stop()
            running = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        finishTerminal(nil)
    }

    func cancel(accountID: UUID) async {
        guard self.accountID == accountID else { return }
        await stopAndWait()
    }

    func stopAndWait() async {
        let pending = task
        cancel()
        await pending?.value
    }

    private func connect(
        accountID: UUID, accounts: ClaudeAccountsModel, defaults: UserDefaults
    ) async throws {
        try await accounts.load()
        try Task.checkCancellation()
        guard let account = accounts.account(accountID) else {
            throw ClaudeAccountError.rejected("This account was removed. Choose another account.")
        }
        let storage = accounts.storage
        let profileID = UUID()
        let launch = try ClaudeLimitsLoginLaunch.prepare(
            account: account, profileID: profileID,
            folder: storage.directory.appendingPathComponent(profileID.uuidString),
            command: HerdrLaunchSettings.command(for: "Claude Code", in: defaults),
            sharedEnvironment: HerdrLaunchSettings.sharedEnvironment(in: defaults),
            inheritedEnvironment: inheritedEnvironment())
        let run = runTerminal
        _ = try await storage.connectLimitsLogin(
            account: account, newProfileID: profileID,
            startLogin: { [weak self] id, folder in
                guard id == profileID, folder.path == launch.currentDirectory else {
                    throw ClaudeAccountError.invalidRequest
                }
                guard let self else { throw CancellationError() }
                let code = try await run(self, launch)
                try Task.checkCancellation()
                guard code == 0 else {
                    throw ClaudeAccountError.rejected(
                        "Subscription sign-in did not finish. Try again.")
                }
            }, eraseScopedSecret: eraseScopedSecret)
        try Task.checkCancellation()
        try? await accounts.load()
        await accounts.notifyChanged()
    }

    func runHeldTerminal(_ launch: ClaudeLimitsLoginLaunch) async throws -> Int32? {
        try Task.checkCancellation()
        holder.stop()
        holder.onExit = { [weak self] code in self?.finishTerminal(code) }
        defer {
            holder.onExit = nil
            holder.stop()
        }
        let code = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                exitWaiter = continuation
                holder.start(
                    executable: launch.executable, arguments: launch.arguments,
                    environment: launch.environment, currentDirectory: launch.currentDirectory,
                    allowsLocalFileLinks: false)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishTerminal(nil) }
        }
        try Task.checkCancellation()
        return code
    }

    private func finishTerminal(_ code: Int32?) {
        exitWaiter?.resume(returning: code)
        exitWaiter = nil
    }

    private static func message(_ error: Error) -> String {
        if case ClaudeAccountError.rejected(let reason) = error { return reason }
        return "Subscription sign-in did not finish. Try again."
    }
}
