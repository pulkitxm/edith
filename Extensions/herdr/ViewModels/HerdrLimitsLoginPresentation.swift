import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class HerdrLimitsLoginPresentation {
    let holder = TerminalSessionHolder()
    private(set) var state: HerdrLimitsLoginState?
    private(set) var error: String?
    private(set) var running = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var accounts: ClaudeAccountsModel?

    func start(accountID: UUID, accounts: ClaudeAccountsModel, defaults: UserDefaults) {
        guard task == nil, !running else {
            error = "Close the current subscription sign-in before starting another."
            return
        }
        self.accounts = accounts
        running = true
        error = nil
        state = HerdrLimitsLoginState(accountID: accountID, ticket: UUID(), phase: .connecting)
        let task = Task { [self] in
            var closed = true
            do {
                guard let ticket = state?.ticket else { throw ExtensionPeerError.invalidRequest }
                state = try await accounts.startLimitsLogin(
                    accountID, ticket: ticket, defaults: defaults)
                while let current = state, current.phase == .connecting {
                    try Task.checkCancellation()
                    if let handle = current.session, holder.descriptor?.handle != handle {
                        let descriptor = OwnedTerminalDescriptor(
                            handle: handle, directory: "/", allowsLocalFileLinks: false,
                            resetTerminalAfterInterrupt: false)
                        holder.bind(
                            try OwnedTerminalClient(descriptor: descriptor) { operation, payload in
                                try await accounts.limitsTerminal(operation, payload: payload)
                            })
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    state = try await accounts.limitsLoginStatus(current)
                }
                if state?.phase == .failed {
                    error = "Subscription sign-in did not finish. Try again."
                }
                if state?.phase == .connected { await accounts.read() }
            } catch {
                if !Task.isCancelled {
                    self.error = "Subscription sign-in did not finish. Try again."
                }
                if let current = state {
                    closed = await close(current, accounts: accounts)
                }
            }
            if closed { await holder.stopRenderingAndWait() }
            running = !closed
            self.task = nil
        }
        self.task = task
        HerdrWorkOwnership.retain(task)
    }

    func cancel() {
        if let task { task.cancel(); return }
        guard running, let current = state, let accounts else { return }
        let task = Task { [self] in
            let closed = await close(current, accounts: accounts)
            if closed { await holder.stopRenderingAndWait() }
            running = !closed
            self.task = nil
        }
        self.task = task
        HerdrWorkOwnership.retain(task)
    }

    func stopAndWait() async {
        cancel()
        let pending = task
        await pending?.value
        await holder.stopRenderingAndWait()
    }

    private func close(_ current: HerdrLimitsLoginState, accounts: ClaudeAccountsModel) async
        -> Bool
    {
        let cleanup = Task.detached { @MainActor in
            var closing = try await accounts.cancelLimitsLogin(current)
            while closing.phase == .connecting {
                try await Task.sleep(for: .milliseconds(250))
                closing = try await accounts.limitsLoginStatus(closing)
            }
            return closing
        }
        do {
            state = try await cleanup.value
            return true
        } catch ExtensionPeerError.invalidRequest {
            state?.phase = .cancelled
            state?.session = nil
            return true
        } catch {
            self.error = "Subscription sign-in could not be closed. Try cancelling again."
            return false
        }
    }
}
