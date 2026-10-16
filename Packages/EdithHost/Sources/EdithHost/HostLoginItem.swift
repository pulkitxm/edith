import Foundation
import ServiceManagement

enum HostLoginItem {
    static let approvalRequestedKey = "host.loginItem.approvalRequested"

    enum Registration: String {
        case notRegistered, enabled, awaitingApproval, notFound

        var title: String {
            switch self {
            case .notRegistered: "Not registered"
            case .enabled: "Enabled"
            case .awaitingApproval: "Waiting for approval"
            case .notFound: "Not found"
            }
        }

        var needsAttention: Bool { self != .enabled }
    }

    static var registration: Registration {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .awaitingApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    static func register(defaults: UserDefaults = .standard) {
        retireLegacyServices()
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            requestApproval(defaults: defaults)
        default:
            do { try service.register() } catch {
                NSLog("Edith could not register as a login item: %@", error.localizedDescription)
            }
            if service.status == .requiresApproval { requestApproval(defaults: defaults) }
        }
    }

    private static func requestApproval(defaults: UserDefaults) {
        guard !defaults.bool(forKey: approvalRequestedKey) else { return }
        defaults.set(true, forKey: approvalRequestedKey)
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func retireLegacyServices() {
        let identifiers = [
            "com.pulkit.edith.helper.v2", "com.pulkit.edith.helper", "com.pulkit.edith.statusbar",
            "com.pulkit.edith.panel", "com.pulkit.edith.bar", "com.pulkit.edith.menubar",
        ]
        let services =
            identifiers.map { SMAppService.loginItem(identifier: $0) } + [
                SMAppService.agent(plistName: "com.pulkit.edith.agent.plist")
            ]
        for service in services where service.status != .notRegistered {
            service.unregister { _ in }
        }
    }
}
