import EdithExtensionSupport
import EdithHostCore
import Foundation

struct HostBackgroundOwnerPin: Sendable {
    let state: HostCLIProviderState
    let process: ExtensionProcessIdentity

    init(state: HostCLIProviderState) throws {
        guard state.available, let pid = state.processIdentifier,
            let process = ExtensionProcessIdentity.read(pid), process.isAlive
        else {
            throw HostCLIError.rejected("The background owner is unavailable.")
        }
        self.state = state
        self.process = process
    }

    func accepts(_ states: [HostCLIProviderState]) -> Bool {
        state.available && process.isAlive && states.contains(state)
    }
}
