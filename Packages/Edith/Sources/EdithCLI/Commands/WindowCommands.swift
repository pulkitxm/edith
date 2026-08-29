import ArgumentParser
import EdithKit
import Foundation

struct WindowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window", abstract: "Arrange the active window.",
        subcommands: [
            WindowStatusCommand.self, WindowLeftHalfCommand.self, WindowRightHalfCommand.self,
            WindowTopHalfCommand.self, WindowBottomHalfCommand.self, WindowTopLeftCommand.self,
            WindowTopRightCommand.self, WindowBottomLeftCommand.self, WindowBottomRightCommand.self,
            WindowCenterCommand.self, WindowMaximizeCommand.self, WindowNextDisplayCommand.self,
            WindowRestoreCommand.self, WorkspaceRestorerCommand.self,
        ], defaultSubcommand: WindowStatusCommand.self)
}

struct WorkspaceRestorerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace", abstract: "Capture and restore named workspace profiles.",
        subcommands: [
            WorkspaceProfileListCommand.self, WorkspaceProfileCaptureCommand.self,
            WorkspaceProfilePreviewCommand.self, WorkspaceProfileRestoreCommand.self,
            WorkspaceProfileCancelCommand.self, WorkspaceProfileRecoverCommand.self,
            WorkspaceProfileRenameCommand.self, WorkspaceProfileDuplicateCommand.self,
            WorkspaceProfileDeleteCommand.self, WorkspaceProfileExportCommand.self,
            WorkspaceProfileImportCommand.self, WorkspaceProfileHistoryCommand.self,
        ], defaultSubcommand: WorkspaceProfileListCommand.self)
}

private enum WorkspaceCLI {
    static func requireEnabled() throws {
        guard
            CLIEnvironment.sharedDefaults.object(
                forKey: AppStorageKeys.WorkspaceRestorer.enabled) as? Bool == true
        else {
            throw CLIFailure.unavailable(
                "the Workspace Restorer extension is off",
                hint: "run `ed extensions enable workspaceRestorer`, then retry")
        }
    }

    static func request(
        _ operation: WorkspaceRestorerOperation, profile: String? = nil,
        options: WorkspaceRestoreOptions = WorkspaceRestoreOptions()
    ) async throws -> WorkspaceRestorerResponse {
        try requireEnabled()
        try AppBridge.requireHelper("managing workspace profiles")
        let request = WorkspaceRestorerRequest(
            operation: operation, profile: profile, options: options)
        guard let payload = WorkspaceRestorerIPC.payload(request) else {
            throw CLIFailure("could not encode the workspace request")
        }
        let reply = await AppBridge.awaitReply(
            IPC.Name.workspaceRestorerResult, timeout: options.timeout + 3,
            matching: {
                WorkspaceRestorerIPC.decode(WorkspaceRestorerResponse.self, from: $0)?.requestID
                    == request.id
            }, trigger: { AppBridge.post(IPC.Name.requestWorkspaceRestorer, userInfo: payload) })
        guard let reply,
            let response = WorkspaceRestorerIPC.decode(
                WorkspaceRestorerResponse.self, from: reply)
        else {
            throw AppBridge.silence(
                "Workspace Restorer", extensionKey: AppStorageKeys.WorkspaceRestorer.enabled,
                permission: "accessibility")
        }
        guard response.ok else { throw CLIFailure(response.error ?? "workspace operation failed") }
        return response
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        CLIOut.out(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func printPlan(_ plan: WorkspaceRestorePlan) {
        CLIOut.out("Workspace: \(plan.profileName)")
        CLIOut.out(
            TextTable.render(
                headers: ["APP", "WINDOW", "MATCH", "ACTION", "DISPLAY"],
                rows: plan.items.map {
                    [
                        $0.applicationName, $0.title.isEmpty ? "untitled" : $0.title,
                        $0.confidence.rawValue, $0.disposition.rawValue,
                        "\($0.sourceDisplayID) → \($0.targetDisplayID)",
                    ]
                }))
    }

    static func printRun(_ run: WorkspaceRestoreRun) {
        CLIOut.out(
            TextTable.render(
                headers: ["APP", "WINDOW", "MATCH", "RESULT"],
                rows: run.items.map {
                    [
                        $0.applicationName, $0.title.isEmpty ? "untitled" : $0.title,
                        $0.confidence.rawValue, $0.state.rawValue,
                    ]
                }))
    }

    static func options(
        launchMissing: Bool, timeout: Double, concurrency: Int
    ) -> WorkspaceRestoreOptions {
        WorkspaceRestoreOptions(
            launchPolicy: launchMissing ? .missing : .never, timeout: timeout,
            concurrency: concurrency)
    }
}

struct WorkspaceProfileListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List profiles.")
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let profiles = WorkspaceRestorerStore.load(defaults: CLIEnvironment.sharedDefaults)
                .profiles
            if json {
                try WorkspaceCLI.printJSON(profiles)
            } else if profiles.isEmpty {
                CLIOut.note("no workspace profiles are saved")
            } else {
                CLIOut.out(
                    TextTable.render(
                        headers: ["NAME", "WINDOWS", "DISPLAYS", "CAPTURED"],
                        rows: profiles.map {
                            [
                                $0.name, "\($0.windows.count)", "\($0.displays.count)",
                                JSONSerializer.iso.string(from: $0.capturedAt),
                            ]
                        }))
            }
        }
    }
}

struct WorkspaceProfileCaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture", abstract: "Capture the current workspace.")
    @Argument var name: String
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let response = try await WorkspaceCLI.request(.capture, profile: name)
            if json {
                try WorkspaceCLI.printJSON(response)
            } else {
                CLIOut.out(
                    "captured \(response.profile?.windows.count ?? 0) windows as \(name)")
            }
        }
    }
}

struct WorkspaceProfilePreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview", abstract: "Preview window matching and display remapping.")
    @Argument var profile: String
    @Flag(name: .long) var launchMissing = false
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let response = try await WorkspaceCLI.request(
                .preview, profile: profile,
                options: WorkspaceCLI.options(
                    launchMissing: launchMissing, timeout: 12, concurrency: 1))
            if json {
                try WorkspaceCLI.printJSON(response)
            } else if let plan = response.plan {
                WorkspaceCLI.printPlan(plan)
            }
        }
    }
}

struct WorkspaceProfileRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "Restore a workspace profile.")
    @Argument var profile: String
    @Flag(name: .long) var launchMissing = false
    @Option(name: .long) var timeout = 12.0
    @Option(name: .long) var concurrency = 1
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let response = try await WorkspaceCLI.request(
                .restore, profile: profile,
                options: WorkspaceCLI.options(
                    launchMissing: launchMissing, timeout: timeout, concurrency: concurrency))
            if json {
                try WorkspaceCLI.printJSON(response)
            } else if let run = response.run {
                WorkspaceCLI.printRun(run)
            }
        }
    }
}

struct WorkspaceProfileCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel", abstract: "Cancel the active restore.")
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let response = try await WorkspaceCLI.request(.cancel)
            if json {
                try WorkspaceCLI.printJSON(response)
            } else {
                CLIOut.out("workspace restore cancellation requested")
            }
        }
    }
}

struct WorkspaceProfileRecoverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover", abstract: "Restore the automatic pre-restore snapshot.")
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let response = try await WorkspaceCLI.request(.recover)
            if json {
                try WorkspaceCLI.printJSON(response)
            } else if let run = response.run {
                WorkspaceCLI.printRun(run)
            }
        }
    }
}

struct WorkspaceProfileRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename", abstract: "Rename a profile.")
    @Argument var profile: String
    @Argument var name: String
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            var library = WorkspaceRestorerStore.load(defaults: CLIEnvironment.sharedDefaults)
            let renamed = try library.rename(profile, to: name)
            try WorkspaceRestorerStore.save(library, defaults: CLIEnvironment.sharedDefaults)
            AppBridge.post(IPC.Name.workspaceRestorerChanged)
            if json {
                try WorkspaceCLI.printJSON(renamed)
            } else {
                CLIOut.out("renamed to \(name)")
            }
        }
    }
}

struct WorkspaceProfileDuplicateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicate", abstract: "Duplicate a profile.")
    @Argument var profile: String
    @Argument var name: String
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            var library = WorkspaceRestorerStore.load(defaults: CLIEnvironment.sharedDefaults)
            let copy = try library.duplicate(profile, as: name)
            try WorkspaceRestorerStore.save(library, defaults: CLIEnvironment.sharedDefaults)
            AppBridge.post(IPC.Name.workspaceRestorerChanged)
            if json {
                try WorkspaceCLI.printJSON(copy)
            } else {
                CLIOut.out("duplicated as \(name)")
            }
        }
    }
}

struct WorkspaceProfileDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete", abstract: "Delete a profile.")
    @Argument var profile: String
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            var library = WorkspaceRestorerStore.load(defaults: CLIEnvironment.sharedDefaults)
            try library.remove(profile)
            try WorkspaceRestorerStore.save(library, defaults: CLIEnvironment.sharedDefaults)
            AppBridge.post(IPC.Name.workspaceRestorerChanged)
            if json {
                CLIOut.json(.object(["deleted": .bool(true)]))
            } else {
                CLIOut.out("workspace profile deleted")
            }
        }
    }
}

struct WorkspaceProfileExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export a profile as JSON.")
    @Argument var profile: String
    @Argument var path: String
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let value = try WorkspaceRestorerStore.load(defaults: CLIEnvironment.sharedDefaults)
                .resolve(profile)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
            if json {
                CLIOut.json(.object(["path": .string(path)]))
            } else {
                CLIOut.out("exported workspace profile to \(path)")
            }
        }
    }
}

struct WorkspaceProfileImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Import a profile from JSON.")
    @Argument var path: String
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let profile = try JSONDecoder().decode(
                WorkspaceProfile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            var library = WorkspaceRestorerStore.load(defaults: CLIEnvironment.sharedDefaults)
            library.upsert(profile)
            try WorkspaceRestorerStore.save(library, defaults: CLIEnvironment.sharedDefaults)
            AppBridge.post(IPC.Name.workspaceRestorerChanged)
            if json {
                try WorkspaceCLI.printJSON(profile)
            } else {
                CLIOut.out("imported workspace profile \(profile.name)")
            }
        }
    }
}

struct WorkspaceProfileHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "Show restore history.")
    @Flag(name: .long) var json = false
    func run() async throws {
        try await execute {
            let history = WorkspaceRestorerStore.load(defaults: CLIEnvironment.sharedDefaults)
                .history
            if json {
                try WorkspaceCLI.printJSON(history)
            } else if history.isEmpty {
                CLIOut.note("workspace restore history is empty")
            } else {
                CLIOut.out(
                    TextTable.render(
                        headers: ["PROFILE", "RESULT", "RESTORED", "FAILED"],
                        rows: history.map {
                            [
                                $0.profileName,
                                $0.dryRun ? "dry-run" : ($0.cancelled ? "cancelled" : "complete"),
                                "\($0.items.filter { $0.state == .restored }.count)",
                                "\($0.items.filter { $0.state == .failed }.count)",
                            ]
                        }))
            }
        }
    }
}

struct WindowStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show Window Tools settings and actions.")
    @Flag(name: .long) var json = false

    func run() async throws {
        try await execute {
            let enabled =
                CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.WindowTools.enabled)
                as? Bool ?? false
            let greenButton =
                CLIEnvironment.sharedDefaults.object(
                    forKey: AppStorageKeys.WindowTools.greenButtonMaximizes) as? Bool ?? true
            let helperRunning = AppBridge.helperIsRunning
            let accessibilityGranted =
                PermissionsStatus.granted(defaults: CLIEnvironment.sharedDefaults)[.accessibility]
                ?? false
            let available = enabled && helperRunning && accessibilityGranted
            if json {
                CLIOut.json(
                    .object([
                        "actions": .strings(WindowLayoutAction.allCases.map(\.rawValue)),
                        "accessibilityGranted": .bool(accessibilityGranted),
                        "available": .bool(available),
                        "enabled": .bool(enabled),
                        "greenButtonMaximizes": .bool(greenButton),
                        "helperRunning": .bool(helperRunning),
                    ]))
            } else {
                CLIOut.out("Window Tools: \(enabled ? "on" : "off")")
                CLIOut.out("Green button maximize: \(greenButton ? "on" : "off")")
                CLIOut.out("Helper: \(helperRunning ? "running" : "not running")")
                CLIOut.out(
                    "Accessibility: \(accessibilityGranted ? "granted" : "not granted")")
                CLIOut.out("Available: \(available ? "yes" : "no")")
                CLIOut.out(
                    "Actions: \(WindowLayoutAction.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
        }
    }
}

private func requestWindowLayout(_ action: WindowLayoutAction, json: Bool) async throws {
    try await execute {
        guard
            CLIEnvironment.sharedDefaults.object(forKey: AppStorageKeys.WindowTools.enabled)
                as? Bool == true
        else {
            throw CLIFailure.unavailable(
                "the Window Tools extension is off",
                hint: "run `ed extensions enable windowTools`, then retry")
        }
        try AppBridge.requireHelper("arranging a window")
        let descriptor = WindowLayoutRequest.send(action) { AppBridge.post($0, userInfo: $1) }
        if json {
            CLIOut.json(
                .object([
                    "action": .string(action.rawValue),
                    "operation": .string(descriptor.id.rawValue),
                    "requested": .bool(true),
                ]))
        } else {
            CLIOut.out("window \(action.rawValue) requested")
        }
    }
}

struct WindowLeftHalfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "left-half", abstract: WindowLayoutAction.leftHalf.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.leftHalf, json: json) }
}

struct WindowRightHalfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "right-half", abstract: WindowLayoutAction.rightHalf.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.rightHalf, json: json) }
}

struct WindowTopHalfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top-half", abstract: WindowLayoutAction.topHalf.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.topHalf, json: json) }
}

struct WindowBottomHalfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottom-half", abstract: WindowLayoutAction.bottomHalf.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.bottomHalf, json: json) }
}

struct WindowTopLeftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top-left", abstract: WindowLayoutAction.topLeft.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.topLeft, json: json) }
}

struct WindowTopRightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top-right", abstract: WindowLayoutAction.topRight.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.topRight, json: json) }
}

struct WindowBottomLeftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottom-left", abstract: WindowLayoutAction.bottomLeft.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.bottomLeft, json: json) }
}

struct WindowBottomRightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottom-right", abstract: WindowLayoutAction.bottomRight.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.bottomRight, json: json) }
}

struct WindowCenterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "center", abstract: WindowLayoutAction.center.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.center, json: json) }
}

struct WindowMaximizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maximize", abstract: WindowLayoutAction.maximize.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.maximize, json: json) }
}

struct WindowNextDisplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next-display", abstract: WindowLayoutAction.nextDisplay.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.nextDisplay, json: json) }
}

struct WindowRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: WindowLayoutAction.restore.descriptor.summary)
    @Flag(name: .long) var json = false
    func run() async throws { try await requestWindowLayout(.restore, json: json) }
}
