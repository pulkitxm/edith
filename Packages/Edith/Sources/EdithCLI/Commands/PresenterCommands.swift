import ArgumentParser
import EdithKit
import Foundation

struct PresenterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "presenter", abstract: "Manual presenter mode at runtime.",
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
        commandName: "status", abstract: "Show presenter runtime state.")
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() async throws {
        PresenterCLI.output(
            PresenterRuntimeOperationExecution.status(defaults: CLIEnvironment.sharedDefaults),
            action: "status", json: json)
    }
}

struct PresenterStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start manual presenter mode.")
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
        commandName: "stop", abstract: "Stop manual presenter mode.")
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
