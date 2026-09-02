import EdithKit
import Foundation
import ServiceManagement

@MainActor
final class AgentRegistrar {
    private let service = SMAppService.agent(plistName: AgentService.plistName)
    private var refresh: DispatchWorkItem?

    func register() {
        switch service.status {
        case .enabled:
            publish()
        case .requiresApproval:
            publish()
        case .notRegistered, .notFound:
            attemptRegistration()
        @unknown default:
            publish()
        }
    }

    func restart() {
        try? service.unregister()
        attemptRegistration()
    }

    private func attemptRegistration() {
        do {
            try service.register()
        } catch {
            let failure = error as NSError
            let approvalPending =
                service.status == .requiresApproval
                || (failure.domain == "SMAppServiceErrorDomain" && failure.code == 1)
            if !approvalPending {
                NSLog(
                    "Background agent registration failed (%@ %ld): %@", failure.domain,
                    failure.code, failure.localizedDescription)
            }
        }
        publish()
    }

    private func publish() {
        let state: AgentRegistrationState =
            switch service.status {
            case .enabled: .enabled
            case .requiresApproval: .awaitingApproval
            case .notRegistered: .notRegistered
            case .notFound: .notFound
            @unknown default: .notFound
            }
        SharedDefaults.store.set(state.rawValue, forKey: AgentService.stateKey)
        refresh?.cancel()
        guard state == .awaitingApproval else { return }
        let work = DispatchWorkItem { [weak self] in self?.publish() }
        refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
