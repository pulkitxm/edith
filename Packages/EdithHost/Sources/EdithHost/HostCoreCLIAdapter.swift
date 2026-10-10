import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum HostCoreCLIAdapter {
    static func make(
        identity: HostIdentity, marketplace: HostMarketplace, updater: HostUpdater,
        shared: UserDefaults, standard: UserDefaults,
        showMainWindow: @escaping @MainActor () -> Void,
        navigation: @escaping HostAppCLIAdapter.Navigation,
        changed: @escaping @MainActor () -> Void
    ) throws -> HostCoreCLIService {
        let permissionState = HostPermissions()
        let permissions = HostPermissionCLIAdapter(
            permissions: permissionState, marketplace: marketplace)
        let app = HostAppCLIAdapter(
            identity: identity, marketplace: marketplace, updater: updater,
            showMainWindow: showMainWindow, navigation: navigation,
            relaunch: {
                throw HostCLIError.rejected(
                    "Relaunch must be performed by the matching CLI caller.")
            })
        let gateway = HostCLIGateway(marketplace: marketplace)
        let camera = HostCameraLifecycleCLI(
            invoke: { try await gateway.execute($0) },
            missingPermissions: {
                await permissionState.refresh()
                try Task.checkCancellation()
                return await permissionState.usages(
                    entries: marketplace.entries, activeIDs: ["virtualCamera"]
                ).filter { $0.requiredBy.contains { $0.id == "virtualCamera" } && !$0.isGranted }
                    .map { $0.permission.rawValue }
            })
        return HostCoreCLIService(
            configuration: try HostConfigurationCLI(
                shared: shared, standard: standard, changed: changed),
            commands: commands,
            action: { arguments in
                let remainder = Array(arguments.dropFirst())
                switch arguments.first {
                case "app": return try await app.execute(remainder)
                case "permissions": return try await permissions.execute(remainder)
                case "camera": return try await camera.execute(remainder)
                default: throw HostCLIError.usage("Unknown core command.")
                }
            })
    }

    private static var commands: [HostCLIProviderCommand] {
        let app = (["actions"] + HostAppCommandCLI.actions).map { action in
            HostCLIProviderCommand(
                route: ["app", action], operation: "host.cli", summary: "Run ed app \(action).",
                destructive: ["quit", "relaunch", "clear-updates"].contains(action),
                timeout: action == "check-updates" ? 65 : 30)
        }
        return app
            + ["ls", "refresh", "request", "settings"].map { action in
                HostCLIProviderCommand(
                    route: ["permissions", action], operation: "host.cli",
                    summary: "Run ed permissions \(action).")
            }
    }
}
