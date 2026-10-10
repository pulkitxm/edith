import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor final class HostPermissionCLIAdapter {
    private let permissions: HostPermissions
    private let entries: () -> [HostExtension]
    private let activeIDs: () -> Set<String>
    private let defaults: UserDefaults?

    init(permissions: HostPermissions, marketplace: HostMarketplace, defaults: UserDefaults? = nil)
    {
        self.permissions = permissions; entries = { marketplace.entries }
        activeIDs = { marketplace.sessions.enabledIDs }
        self.defaults = defaults
    }

    init(
        permissions: HostPermissions, entries: @escaping () -> [HostExtension],
        activeIDs: @escaping () -> Set<String>, defaults: UserDefaults? = nil
    ) {
        self.permissions = permissions; self.entries = entries; self.activeIDs = activeIDs
        self.defaults = defaults
    }

    func refresh() async throws {
        await permissions.refresh()
        try Task.checkCancellation()
        recordObservedGrants()
    }

    private func recordObservedGrants() {
        for (permission, granted) in permissions.granted {
            if let key = permission.grantedDefaultsKey { defaults?.set(granted, forKey: key) }
        }
    }

    func execute(_ arguments: [String]) async throws -> ExtensionCLIReply {
        var words = arguments
        let json = words.contains("--json")
        let attention = words.contains("--attention")
        guard words.filter({ $0 == "--json" }).count <= 1,
            words.filter({ $0 == "--attention" }).count <= 1
        else { throw HostCLIError.usage("Duplicate permission flag.") }
        words.removeAll { $0 == "--json" || $0 == "--attention" }
        let action = words.isEmpty ? "ls" : words.removeFirst()
        let values: HostCLIJSON
        switch action {
        case "ls", "list", "refresh":
            guard words.isEmpty, !attention || action != "refresh" else {
                throw HostCLIError.usage("Invalid permission arguments.")
            }
            try await refresh()
            var rows = permissions.usages(
                entries: entries(), activeIDs: activeIDs())
            if attention { rows = rows.filter(\.blocksEnabledExtension) }
            let items = rows.map(Self.json)
            values =
                action == "refresh"
                ? .array(items)
                : .object(["appRunning": .bool(true), "permissions": .array(items)])
            if !json {
                let text = Self.table(rows)
                return try ExtensionCLIReply(stdout: text + "\n", stderr: "", exitCode: 0)
            }
        case "request", "settings":
            guard words.count == 1, !attention,
                let permission = HostPermission.allCases.first(where: {
                    $0.rawValue.lowercased() == words[0].lowercased()
                })
            else { throw HostCLIError.usage("Unknown permission or invalid arguments.") }
            if action == "request" {
                guard !permission.grantsOnFirstUse else {
                    throw HostCLIError.rejected(
                        permission.firstUseExplanation ?? "This permission is granted on first use."
                    )
                }
                await permissions.request(permission)
                try Task.checkCancellation()
                recordObservedGrants()
                let granted = permissions.granted[permission] == true
                values = .object([
                    "permission": .string(permission.rawValue), "requested": .bool(true),
                    "granted": .bool(granted),
                    "relaunch": .string(
                        permission == .screenRecording || permission == .inputMonitoring
                            ? "edith" : "none"),
                    "relaunchRequired": .bool(
                        granted
                            && (permission == .screenRecording || permission == .inputMonitoring)),
                ])
                if !json {
                    return try ExtensionCLIReply(
                        stdout:
                            "\(permission.rawValue) \(granted ? "granted" : "not granted yet")\n",
                        stderr: "", exitCode: 0)
                }
            } else {
                guard let url = permission.settingsURL else {
                    throw HostCLIError.rejected(
                        permission.firstUseExplanation ?? "No settings pane exists.")
                }
                let opened = permissions.openSettings(permission)
                values = .object([
                    "permission": .string(permission.rawValue), "opened": .bool(opened),
                    "url": .string(url.absoluteString),
                ])
                if !opened { throw HostCLIError.rejected("Could not open System Settings.") }
                if !json {
                    return try ExtensionCLIReply(
                        stdout: "opened System Settings for \(permission.rawValue)\n", stderr: "",
                        exitCode: 0)
                }
            }
        default: throw HostCLIError.usage("Unknown permissions command.")
        }
        return try ExtensionCLIReply(
            stdout: String(decoding: values.encoded(), as: UTF8.self) + "\n", stderr: "",
            exitCode: 0)
    }

    private static func json(_ usage: HostPermissionUsage) -> HostCLIJSON {
        .object([
            "id": .string(usage.permission.rawValue), "name": .string(usage.permission.displayName),
            "reason": .string(usage.permission.reason), "granted": .bool(usage.isGranted),
            "grantsOnFirstUse": .bool(usage.grantsOnFirstUse),
            "requiredBy": .strings(usage.requiredBy.map(\.id)),
            "optionalFor": .strings(usage.optionalFor.map(\.id)),
            "usedByEnabledExtension": .bool(usage.isUsedByEnabledExtension),
            "blocksEnabledExtension": .bool(usage.blocksEnabledExtension),
        ])
    }
    private static func table(_ rows: [HostPermissionUsage]) -> String {
        (["PERMISSION  STATE  USED BY"]
            + rows.map {
                "\($0.permission.rawValue)  \($0.isGranted ? "granted" : $0.grantsOnFirstUse ? "on first use" : "no")  \($0.enabledUsers.map(\.id).joined(separator: ","))"
            }).joined(separator: "\n")
    }
}
