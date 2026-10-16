import Foundation
import ServiceManagement

enum HostLoginItem {
    static let approvalRequestedKey = "host.loginItem.approvalRequested"

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
        let services = [
            SMAppService.loginItem(identifier: "com.pulkit.edith.helper.v2"),
            SMAppService.loginItem(identifier: "com.pulkit.edith.helper"),
            SMAppService.agent(plistName: "com.pulkit.edith.agent.plist"),
        ]
        for service in services where service.status != .notRegistered {
            service.unregister { _ in }
        }
    }
}
