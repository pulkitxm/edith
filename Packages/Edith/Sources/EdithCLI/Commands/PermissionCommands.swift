import ArgumentParser
import EdithKit
import Foundation

struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Inspect and request the macOS permissions Edith uses.",
        discussion: """
            A command line process cannot read another app's TCC state, so `ed` reports
            what the Edith app itself last observed and mirrored into its preferences.
            `ed permissions refresh` asks the running app to re-read the real state
            first; `ed permissions request` asks it to raise the system prompt.
            """,
        subcommands: [
            PermissionsListCommand.self, PermissionsRequestCommand.self,
            PermissionsRefreshCommand.self, PermissionsSettingsCommand.self,
        ],
        defaultSubcommand: PermissionsListCommand.self)
}

enum PermissionLookup {
    static var center: PermissionOperationCenter {
        PermissionOperationCenter(
            environment: PermissionOperationEnvironment(
                defaults: CLIEnvironment.sharedDefaults,
                requestPermission: { permission in
                    guard let request = permission.grantRequest else { return false }
                    CLIEnvironment.deliver(request, nil)
                    return false
                },
                refreshStatus: {
                    CLIEnvironment.deliver(IPC.Name.requestPermissionsRefresh, nil)
                },
                openSettings: { CLIEnvironment.openURL($0) }))
    }

    static func permission(_ name: String) throws -> ExtensionPermission {
        let needle = name.lowercased()
        if let match = ExtensionPermission.allCases.first(where: {
            $0.rawValue.lowercased() == needle
        }) {
            return match
        }
        throw CLIFailure.notFound(
            "no permission named \(name)",
            hint: "known: " + ExtensionPermission.allCases.map(\.rawValue).joined(separator: ", "))
    }

    static func json(_ usage: PermissionUsage) -> JSONValue {
        .object([
            "id": .string(usage.permission.rawValue),
            "name": .string(usage.permission.displayName),
            "reason": .string(usage.permission.reason),
            "granted": .bool(usage.isGranted),
            "grantsOnFirstUse": .bool(usage.grantsOnFirstUse),
            "requiredBy": .strings(usage.requiredBy.map(\.id)),
            "optionalFor": .strings(usage.optionalFor.map(\.id)),
            "usedByEnabledExtension": .bool(usage.isUsedByEnabledExtension),
            "blocksEnabledExtension": .bool(usage.blocksEnabledExtension),
        ])
    }
}

struct PermissionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List permissions as Edith last observed them.",
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Only permissions that block an enabled extension.")
    var attention = false

    func run() async throws {
        let usages = PermissionLookup.center.status(filter: attention ? .attention : .all)
        guard !json else {
            CLIOut.json(
                .object([
                    "appRunning": .bool(AppBridge.helperIsRunning),
                    "permissions": .array(usages.map(PermissionLookup.json)),
                ]))
            return
        }
        let rows = usages.map { usage in
            [
                usage.permission.rawValue,
                usage.isGranted ? "granted" : (usage.grantsOnFirstUse ? "on first use" : "no"),
                usage.blocksEnabledExtension ? "blocking" : "",
                usage.enabledUsers.map(\.id).joined(separator: ","),
            ]
        }
        CLIOut.out(TextTable.render(headers: ["PERMISSION", "STATE", "", "USED BY"], rows: rows))
    }
}

struct PermissionsRequestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "request", abstract: "Ask the running app to request a permission.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The permission id.")
    var permission: String

    func run() async throws {
        try await execute {
            let value = try PermissionLookup.permission(permission)
            guard value.grantRequest != nil else {
                throw CLIFailure.unavailable(
                    "\(value.displayName) is granted on first use and cannot be requested",
                    hint: value.firstUseExplanation)
            }
            try AppBridge.requireHelper("requesting a permission")
            let request = try PermissionLookup.center.request(value)
            try? await Task.sleep(for: .milliseconds(1500))
            _ = PermissionLookup.center.refresh()
            try? await Task.sleep(for: .milliseconds(1000))
            let granted = PermissionLookup.center.remediation(for: value).granted
            guard !json else {
                CLIOut.json(
                    .object([
                        "permission": .string(value.rawValue),
                        "requested": .bool(request.requested),
                        "granted": .bool(granted),
                        "relaunch": .string(request.relaunch.rawValue),
                        "relaunchRequired": .bool(
                            granted && request.relaunch == .edith),
                    ]))
                return
            }
            CLIOut.out("\(value.rawValue) \(granted ? "granted" : "not granted yet")")
            if granted, request.relaunch == .edith {
                CLIOut.note("note: run `ed app relaunch` before using the new grant")
            } else if !granted {
                CLIOut.note(
                    "note: finish the prompt in System Settings, then run `ed permissions refresh`")
            }
        }
    }
}

struct PermissionsRefreshCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh", abstract: "Ask the running app to re-read the real TCC state.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try AppBridge.requireHelper("refreshing permissions")
            _ = PermissionLookup.center.refresh()
            try? await Task.sleep(for: .milliseconds(1200))
            let usages = PermissionLookup.center.status()
            guard !json else {
                CLIOut.json(.array(usages.map(PermissionLookup.json)))
                return
            }
            let rows = usages.map { usage in
                [usage.permission.rawValue, usage.isGranted ? "granted" : "no"]
            }
            CLIOut.out(TextTable.render(headers: ["PERMISSION", "STATE"], rows: rows))
        }
    }
}

struct PermissionsSettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings", abstract: "Open System Settings for a permission.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The permission id.")
    var permission: String

    func run() async throws {
        try await execute {
            let value = try PermissionLookup.permission(permission)
            let result: PermissionSettingsResult
            do {
                result = try PermissionLookup.center.openSettings(for: value)
            } catch let error as PermissionOperationError {
                throw CLIFailure.unavailable(
                    error.localizedDescription, hint: value.firstUseExplanation)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "permission": .string(value.rawValue), "opened": .bool(result.opened),
                        "url": .string(result.url.absoluteString),
                    ]))
                return
            }
            CLIOut.out("opened System Settings for \(value.rawValue)")
        }
    }
}
