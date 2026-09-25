import EdithKit
import Foundation
import ServiceManagement

@MainActor
final class AgentRegistrar {
    private let service = SMAppService.agent(plistName: AgentService.plistName)
    private lazy var approvalRefresher = ApprovalStatusRefresher { [weak self] in self?.publish() }
    private var didRepair = false

    func registerAndRestartIfStale() {
        register()
        guard AgentBuildStamp.hasChanged() else {
            repairIfUnreachable()
            return
        }
        AgentBuildStamp.record()
        reregister(restartingRunningAgent: true)
    }

    private func reregister(restartingRunningAgent: Bool) {
        try? service.unregister()
        attemptRegistration()
        guard restartingRunningAgent else { return }
        restartRunningAgent()
    }

    private func repairIfUnreachable() {
        guard service.status == .enabled, !didRepair else { return }
        DispatchQueue.global(qos: .utility).async {
            guard (try? AgentClient.shared.verifyHandshake()) == nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !didRepair else { return }
                didRepair = true
                AgentClient.shared.reset()
                reregister(restartingRunningAgent: false)
            }
        }
    }

    private func restartRunningAgent() {
        DispatchQueue.global(qos: .utility).async {
            try? AgentClient.shared.restart()
        }
    }

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
        reregister(restartingRunningAgent: true)
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
        SharedDefaults.store.setIfChanged(state.rawValue, forKey: AgentService.stateKey)
        approvalRefresher.update(awaitingApproval: state == .awaitingApproval)
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
