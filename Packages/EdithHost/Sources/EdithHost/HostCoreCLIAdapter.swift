import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum HostCoreCLIAdapter {
    static func make(
        identity: HostIdentity, marketplace: HostMarketplace, updater: HostUpdater,
        shared: UserDefaults, standard: UserDefaults,
        showMainWindow: @escaping @MainActor () -> Void,
        navigation: @escaping HostAppCLIAdapter.Navigation,
        core: @escaping @MainActor () -> HostCoreServices? = { nil },
        changed: @escaping @MainActor () -> Void
    ) throws -> HostCoreCLIService {
        let permissionState = HostPermissions()
        let permissions = HostPermissionCLIAdapter(
            permissions: permissionState, marketplace: marketplace, defaults: shared)
        let app = HostAppCLIAdapter(
            identity: identity, marketplace: marketplace, updater: updater,
            showMainWindow: showMainWindow, navigation: navigation, core: core,
            relaunch: {
                throw HostCLIError.rejected(
                    "Relaunch must be performed by the matching CLI caller.")
            })
        let gateway = HostCLIGateway(marketplace: marketplace)
        let local = HostCommandCLI(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "development",
            tooling: HostToolingCLI(
                home: FileManager.default.homeDirectoryForCurrentUser,
                executable: Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                path: (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(
                    String.init)),
            invoke: { try await gateway.execute($0) })
        let camera = HostCameraLifecycleCLI(
            invoke: { try await gateway.execute($0) },
            missingPermissions: {
                try await permissions.refresh()
                return await permissionState.usages(
                    entries: marketplace.entries, activeIDs: ["virtualCamera"]
                ).filter { $0.requiredBy.contains { $0.id == "virtualCamera" } && !$0.isGranted }
                    .map { $0.permission.rawValue }
            })
        return HostCoreCLIService(
            configuration: try HostConfigurationCLI(
                shared: shared, standard: standard, changed: changed),
            commandProvider: {
                commands.filter { command in
                    (command.route != ["app", "clean-keys"]
                        || marketplace.sessions.activeIDs.contains("system"))
                        && (command.route != ["app", "check-updates"] || updater.available)
                }
            },
            prepareConfiguration: { arguments in
                if arguments.isEmpty
                    || ["ls", "list", "get", "describe"].contains(arguments.first ?? "")
                {
                    try await permissions.refresh()
                }
            },
            action: { arguments in
                let remainder = Array(arguments.dropFirst())
                switch arguments.first {
                case "app": return try await app.execute(remainder)
                case "permissions": return try await permissions.execute(remainder)
                case "camera": return try await camera.execute(remainder)
                default: return try await local.execute(arguments)
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
        let permissions = ["ls", "refresh", "request", "settings"].map { action in
            HostCLIProviderCommand(
                route: ["permissions", action], operation: "host.cli",
                summary: "Run ed permissions \(action).")
        }
        let local = HostCLIHelp.routes.filter { route in
            [
                "guide", "schema", "version", "status", "install", "uninstall", "completions",
                "extensions",
            ].contains(route.first ?? "")
        }.map { route in
            HostCLIProviderCommand(
                route: route, operation: "host.cli",
                summary: "Run ed " + route.joined(separator: " "),
                jsonOutput: route.first != "schema" && route.first != "guide"
                    && route.first != "completions")
        }
        return app + permissions + local
    }
}
