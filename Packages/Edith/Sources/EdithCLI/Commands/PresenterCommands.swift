import ArgumentParser
import EdithKit
import Foundation

struct PresenterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "presenter",
        abstract: "Start, stop, and read manual presenter mode.",
        discussion: """
            Control presenter mode while the Presenter extension is on. Reads and changes
            the manual presenter flag in shared defaults, and posts the change to the
            running app. Status does not change the mode.

            ed presenter status
            ed presenter start
            ed presenter stop
            """,
        subcommands: [
            PresenterStatusCommand.self, PresenterStartCommand.self, PresenterStopCommand.self,
        ], defaultSubcommand: PresenterStatusCommand.self)
}

enum PresenterCLI {
    static func output(_ snapshot: PresenterRuntimeSnapshot, action: String, json: Bool) {
        guard !json else {
            CLIOut.json(
                .object([
                    "action": .string(action), "enabled": .bool(snapshot.enabled),
                    "manual": .bool(snapshot.manual), "autoActive": .bool(snapshot.autoActive),
                    "autoReason": .optional(snapshot.autoReason), "active": .bool(snapshot.active),
                ]))
            return
        }
        if action == "status" {
            CLIOut.out(
                snapshot.active
                    ? "active (\(snapshot.manual ? "manual" : snapshot.autoReason ?? "automatic"))"
                    : "inactive")
        } else {
            CLIOut.out("presenter mode \(snapshot.manual ? "started" : "stopped")")
        }
    }
}

struct PresenterStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show presenter runtime state.",
        discussion: """
            Report whether presenter mode is active, and whether that came from the manual
            switch or from automatic detection. Reads shared defaults. Does not change the mode.

            ed presenter status
            ed presenter status --json
            """)
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() async throws {
        PresenterCLI.output(
            PresenterRuntimeOperationExecution.status(defaults: CLIEnvironment.sharedDefaults),
            action: "status", json: json)
    }
}

struct PresenterStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start manual presenter mode.",
        discussion: """
            Turn manual presenter mode on. Reads whether the Presenter extension is enabled.
            Changes the manual flag and tells the running app. Fails when the extension is off.

            ed presenter start
            ed presenter start --json
            """)
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() async throws {
        try await execute {
            guard
                PresenterRuntimeOperationExecution.status(defaults: CLIEnvironment.sharedDefaults)
                    .enabled
            else {
                throw CLIFailure.unavailable(
                    "the Presenter extension is off",
                    hint: "run `ed extensions enable presenter`")
            }
            PresenterCLI.output(
                PresenterRuntimeOperationExecution.perform(
                    .start, defaults: CLIEnvironment.sharedDefaults,
                    post: { AppBridge.post($0) }),
                action: "start", json: json)
        }
    }
}

struct PresenterStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop manual presenter mode.",
        discussion: """
            Turn manual presenter mode off. Reads whether the Presenter extension is enabled.
            Changes the manual flag and tells the running app. Does not change automatic
            detection settings.

            ed presenter stop
            ed presenter stop --json
            """)
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() async throws {
        try await execute {
            guard
                PresenterRuntimeOperationExecution.status(defaults: CLIEnvironment.sharedDefaults)
                    .enabled
            else {
                throw CLIFailure.unavailable(
                    "the Presenter extension is off",
                    hint: "run `ed extensions enable presenter`")
            }
            PresenterCLI.output(
                PresenterRuntimeOperationExecution.perform(
                    .stop, defaults: CLIEnvironment.sharedDefaults,
                    post: { AppBridge.post($0) }),
                action: "stop", json: json)
        }
    }
}
