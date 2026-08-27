import ArgumentParser
import EdithKit

struct QuickActionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quick-actions", abstract: "One-click controls for common macOS states.",
        subcommands: [
            QuickActionsStatusCommand.self, QuickActionsAppearanceCommand.self,
            QuickActionsKeyboardLightCommand.self, QuickActionsEmptyTrashCommand.self,
            QuickActionsEjectDisksCommand.self, QuickActionsHiddenFilesCommand.self,
            QuickActionsDesktopIconsCommand.self, QuickActionsLockScreenCommand.self,
        ], defaultSubcommand: QuickActionsStatusCommand.self)
}

enum QuickActionsCLI {
    static func requireEnabled() throws {
        guard
            CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.Tabs.quickActionsEnabled)
                as? Bool == true
        else {
            throw CLIFailure.unavailable(
                "the Quick Actions extension is off",
                hint: "run `ed extensions enable quickActions`, then retry")
        }
    }

    static func perform(_ action: QuickAction, json: Bool) throws {
        try requireEnabled()
        let result = try CLIEnvironment.quickActionCenter().perform(action)
        if json {
            CLIOut.json(resultJSON(result, applied: true))
        } else {
            CLIOut.out(result.message)
        }
    }

    static func statusJSON(_ snapshot: QuickActionsSnapshot, enabled: Bool) -> JSONValue {
        .object([
            "actions": .array(
                QuickAction.allCases.map { action in
                    .object([
                        "available": .bool(action.isAvailable(in: snapshot)),
                        "id": .string(commandName(action)),
                        "operation": .string(action.descriptor.id.rawValue),
                        "state": .string(action.stateLabel(in: snapshot)),
                        "visible": .bool(visible(action)),
                    ])
                }),
            "enabled": .bool(enabled),
            "snapshot": snapshotJSON(snapshot),
        ])
    }

    static func resultJSON(_ result: QuickActionResult, applied: Bool) -> JSONValue {
        .object([
            "action": .string(commandName(result.action)),
            "affectedCount": .int(result.affectedCount),
            "applied": .bool(applied),
            "changed": .bool(result.changed),
            "message": .string(result.message),
            "operation": .string(result.action.descriptor.id.rawValue),
            "snapshot": snapshotJSON(result.snapshot),
        ])
    }

    static func snapshotJSON(_ snapshot: QuickActionsSnapshot) -> JSONValue {
        .object([
            "appearance": .string(snapshot.appearance.rawValue),
            "desktopIconsShown": .bool(snapshot.desktopIconsShown),
            "ejectableVolumes": .array(
                snapshot.ejectableVolumes.map {
                    .object(["name": .string($0.name), "path": .string($0.path)])
                }),
            "hiddenFilesShown": .bool(snapshot.hiddenFilesShown),
            "keyboardLightAvailable": .bool(snapshot.keyboardLightAvailable),
            "keyboardLightEnabled": snapshot.keyboardLightEnabled.map(JSONValue.bool) ?? .null,
        ])
    }

    static func commandName(_ action: QuickAction) -> String {
        action.descriptor.cli.last ?? action.rawValue
    }

    static func visible(_ action: QuickAction) -> Bool {
        CLIEnvironment.sharedDefaults.object(forKey: action.visibilityKey) as? Bool ?? true
    }
}

struct QuickActionsStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show every Quick Action state.")
    @Flag(name: .long) var json = false

    func run() async throws {
        try await execute {
            let enabled =
                CLIEnvironment.sharedDefaults.object(
                    forKey: AppStorageKeys.Tabs.quickActionsEnabled) as? Bool ?? false
            let snapshot = CLIEnvironment.quickActionCenter().snapshot()
            if json {
                CLIOut.json(QuickActionsCLI.statusJSON(snapshot, enabled: enabled))
            } else {
                CLIOut.out("Quick Actions: \(enabled ? "on" : "off")")
                for action in QuickAction.allCases {
                    let availability = action.isAvailable(in: snapshot) ? "" : " (unavailable)"
                    CLIOut.out("\(action.title): \(action.stateLabel(in: snapshot))\(availability)")
                }
            }
        }
    }
}

struct QuickActionsAppearanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appearance", abstract: QuickAction.appearance.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute { try QuickActionsCLI.perform(.appearance, json: json) }
    }
}

struct QuickActionsKeyboardLightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyboard-light", abstract: QuickAction.keyboardLight.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute { try QuickActionsCLI.perform(.keyboardLight, json: json) }
    }
}

struct QuickActionsEmptyTrashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "empty-trash", abstract: QuickAction.emptyTrash.descriptor.summary)
    @Flag(name: .long) var json = false
    @Flag(name: .long, help: "Confirm permanent removal of every item in the Trash.") var yes =
        false

    func run() async throws {
        try await execute {
            try QuickActionsCLI.requireEnabled()
            let plan = CLIDestructivePlan(
                action: "empty-trash", targets: ["Trash"], confirmed: yes, json: json,
                fields: ["operation": .string(QuickAction.emptyTrash.descriptor.id.rawValue)])
            guard plan.shouldApply() else { return }
            let result = try CLIEnvironment.quickActionCenter().perform(.emptyTrash)
            plan.finish(
                changed: result.changed, plain: result.message,
                fields: [
                    "affectedCount": .int(result.affectedCount),
                    "message": .string(result.message),
                    "operation": .string(result.action.descriptor.id.rawValue),
                    "snapshot": QuickActionsCLI.snapshotJSON(result.snapshot),
                ])
        }
    }
}

struct QuickActionsEjectDisksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eject-disks", abstract: QuickAction.ejectDisks.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute { try QuickActionsCLI.perform(.ejectDisks, json: json) }
    }
}

struct QuickActionsHiddenFilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hidden-files", abstract: QuickAction.hiddenFiles.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute { try QuickActionsCLI.perform(.hiddenFiles, json: json) }
    }
}

struct QuickActionsDesktopIconsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "desktop-icons", abstract: QuickAction.desktopIcons.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute { try QuickActionsCLI.perform(.desktopIcons, json: json) }
    }
}

struct QuickActionsLockScreenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock-screen", abstract: QuickAction.lockScreen.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute { try QuickActionsCLI.perform(.lockScreen, json: json) }
    }
}
