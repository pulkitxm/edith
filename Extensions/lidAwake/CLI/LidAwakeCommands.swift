import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct LidAwakeCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lid-awake",
        abstract: "Keep the Mac running with its lid closed.",
        discussion: """
            Turn closed-lid mode on or off, and read its session, battery floor, and helper.
            Reads and changes power state through the running app. status does not change it.
            on previews until --yes.

            ed lid-awake status
            ed lid-awake on --for 30m --yes
            """,
        subcommands: [
            LidAwakeStatusCommand.self, LidAwakeOnCommand.self, LidAwakeOffCommand.self,
            LidAwakeBatteryCommand.self, LidAwakeRestoreOnQuitCommand.self,
        ],
        defaultSubcommand: LidAwakeStatusCommand.self)
}

@MainActor enum LidAwakeCLI {
    static func boolean(_ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw CLIFailure.usage("expected true or false")
        }
    }

    static func session(duration: String?, untilLidReopens: Bool) throws -> LidAwakeSession {
        guard !untilLidReopens || duration == nil else {
            throw CLIFailure("--for and --until-lid-reopens cannot be used together")
        }
        if untilLidReopens { return .untilLidReopens }
        guard let duration else { return .indefinite }
        switch duration.lowercased().replacingOccurrences(of: " ", with: "") {
        case "15m", "15min", "15mins", "15minute", "15minutes", "fifteenminutes":
            return .fifteenMinutes
        case "30m", "30min", "30mins", "30minute", "30minutes", "thirtyminutes":
            return .thirtyMinutes
        case "1h", "60m", "60min", "60mins", "1hour", "onehour":
            return .oneHour
        case "2h", "120m", "120min", "120mins", "2hours", "twohours":
            return .twoHours
        default:
            throw CLIFailure(
                "\(duration) is not a Lid Awake session",
                hint: "use 15m, 30m, 1h or 2h")
        }
    }

    static func batteryThreshold(_ raw: String) throws -> Int {
        if ["off", "none", "disabled"].contains(raw.lowercased()) { return 0 }
        guard let threshold = Int(raw), (1...100).contains(threshold) else {
            throw CLIFailure("\(raw) is not a battery percentage from 1 to 100, or off")
        }
        return threshold
    }

    static func request(_ request: LidAwakeRequest) async throws -> LidAwakeSnapshot {
        guard let worker = LidAwakeCLIEnvironment.worker else {
            throw ExtensionPeerError.unavailable
        }
        do { return try await worker.perform(request) } catch {
            throw CLIFailure(error.localizedDescription)
        }
    }

    static func status() async throws -> LidAwakeSnapshot { try await request(.status) }

    static func json(_ snapshot: LidAwakeSnapshot) -> JSONValue {
        .object([
            "extensionEnabled": .bool(snapshot.extensionEnabled),
            "active": .bool(snapshot.active),
            "requestedActive": .bool(snapshot.requestedActive),
            "applying": .bool(snapshot.applying),
            "batterySuspended": .bool(snapshot.batterySuspended),
            "session": .string(snapshot.session.rawValue),
            "remainingSeconds": .optional(snapshot.remainingSeconds),
            "batteryThreshold": .int(snapshot.batteryThreshold),
            "restoreOnQuit": .bool(snapshot.restoreOnQuit),
            "helperStatus": .string(snapshot.helperStatus),
            "appRunning": .bool(snapshot.appRunning),
            "lastError": .optional(snapshot.lastError),
        ])
    }

    static func previewJSON(
        _ preview: LidAwakeOperationPreview, request: LidAwakeRequest
    ) -> JSONValue {
        let session: JSONValue =
            if case .on(let value) = request { .string(value.rawValue) } else { .null }
        let restoreOnQuit: JSONValue =
            if case .setRestoreOnQuit(let value) = request { .bool(value) } else { .null }
        return .object([
            "operation": .string(preview.operation.descriptor.id.rawValue),
            "performed": .bool(false),
            "requiresConfirmation": .bool(true),
            "summary": .string(preview.summary),
            "warning": .string(preview.warning),
            "session": session,
            "restoreOnQuit": restoreOnQuit,
        ])
    }

    static func printPreview(_ preview: LidAwakeOperationPreview) {
        CLIOut.out("preview: \(preview.summary)")
        CLIOut.out("warning: \(preview.warning)")
        CLIOut.out("pass --yes to apply")
    }

    static func printStatus(_ snapshot: LidAwakeSnapshot) {
        let state =
            snapshot.applying
            ? "changing"
            : snapshot.batterySuspended ? "paused on low battery" : snapshot.active ? "on" : "off"
        CLIOut.out("state: \(state)")
        CLIOut.out("session: \(snapshot.session.title)")
        if let remaining = snapshot.remainingSeconds {
            CLIOut.out("remaining: \(Int(remaining.rounded(.up))) seconds")
        }
        CLIOut.out(
            "battery auto-pause: \(snapshot.batteryThreshold == 0 ? "off" : "\(snapshot.batteryThreshold)%")"
        )
        CLIOut.out("restore on quit: \(snapshot.restoreOnQuit ? "on" : "off")")
        CLIOut.out("helper: \(snapshot.helperStatus)")
        CLIOut.out("app running: \(snapshot.appRunning ? "yes" : "no")")
        if let error = snapshot.lastError { CLIOut.out("last error: \(error)") }
    }
}

struct LidAwakeStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: LidAwakeOperation.status.descriptor.summary,
        discussion: """
            Show closed-lid state, the session, the battery floor, and whether the helper is up.
            Reads Lid Awake through the running app. Does not change power state.

            ed lid-awake status
            ed lid-awake status --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            let payload = try await LidAwakeCLI.status()
            if json {
                CLIOut.json(LidAwakeCLI.json(payload))
            } else {
                LidAwakeCLI.printStatus(payload)
            }
        }
    }
}

struct LidAwakeOnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: LidAwakeOperation.on.descriptor.summary,
        discussion: """
            Keep the Mac awake with the lid closed, for 15m, 30m, 1h, 2h, or until the lid reopens.
            Reads whether the extension can run. Without --yes, prints the plan and does not change power. With --yes, changes the power assertion.

            ed lid-awake on
            ed lid-awake on --for 30m --yes
            """,
        aliases: ["start"])

    @Option(name: .customLong("for"), help: "Stop after 15m, 30m, 1h or 2h.")
    var duration: String?

    @Flag(help: "Stop after the lid closes and opens again.")
    var untilLidReopens = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Apply the previewed power-state change.")
    var yes = false

    @MainActor func run() async throws {
        try await execute {
            let session = try LidAwakeCLI.session(
                duration: duration, untilLidReopens: untilLidReopens)
            let request = LidAwakeRequest.on(session)
            if let preview = LidAwakeOperationExecution.preview(for: request), !yes {
                if json {
                    CLIOut.json(LidAwakeCLI.previewJSON(preview, request: request))
                } else {
                    LidAwakeCLI.printPreview(preview)
                }
                return
            }
            let snapshot = try await LidAwakeCLI.request(request)
            if json {
                CLIOut.json(LidAwakeCLI.json(snapshot))
            } else {
                CLIOut.out("lid awake on: \(session.title)")
            }
        }
    }
}

struct LidAwakeOffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off",
        abstract: LidAwakeOperation.off.descriptor.summary,
        discussion: """
            Stop closed-lid mode and release the power assertion.
            Reads the current session through the running app. Changes power state by turning it off.

            ed lid-awake off
            ed lid-awake off --json
            """,
        aliases: ["stop"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            let snapshot = try await LidAwakeCLI.request(.off)
            if json {
                CLIOut.json(LidAwakeCLI.json(snapshot))
            } else {
                CLIOut.out("lid awake off")
            }
        }
    }
}

struct LidAwakeBatteryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "battery",
        abstract: LidAwakeOperation.battery.descriptor.summary,
        discussion: """
            Set the battery percent that pauses Lid Awake, or off to disable the floor.
            Reads the requested percent. Changes the stored battery threshold.

            ed lid-awake battery 20
            ed lid-awake battery off --json
            """)

    @Argument(help: "A percentage from 1 to 100, or off.")
    var threshold: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            let threshold = try LidAwakeCLI.batteryThreshold(threshold)
            _ = try await LidAwakeCLI.request(.setBatteryThreshold(threshold))
            if json {
                CLIOut.json(.object(["batteryThreshold": .int(threshold)]))
            } else {
                CLIOut.out("battery auto-pause = \(threshold == 0 ? "off" : "\(threshold)%")")
            }
        }
    }
}

struct LidAwakeRestoreOnQuitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore-on-quit",
        abstract: LidAwakeOperation.restoreOnQuit.descriptor.summary,
        discussion: """
            Choose whether quitting Edith restores the previous power state.
            Reads true or false. Without --yes, prints the plan and does not change the policy. With --yes, changes the stored policy.

            ed lid-awake restore-on-quit true
            ed lid-awake restore-on-quit false --yes
            """)

    @Argument(help: "true or false.")
    var enabled: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Apply the previewed safety-policy change.")
    var yes = false

    @MainActor func run() async throws {
        try await execute {
            let enabled = try LidAwakeCLI.boolean(enabled)
            let request = LidAwakeRequest.setRestoreOnQuit(enabled)
            if let preview = LidAwakeOperationExecution.preview(for: request), !yes {
                if json {
                    CLIOut.json(LidAwakeCLI.previewJSON(preview, request: request))
                } else {
                    LidAwakeCLI.printPreview(preview)
                }
                return
            }
            _ = try await LidAwakeCLI.request(request)
            if json {
                CLIOut.json(.object(["restoreOnQuit": .bool(enabled)]))
            } else {
                CLIOut.out("restore on quit = \(enabled ? "on" : "off")")
            }
        }
    }
}
