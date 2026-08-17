import ArgumentParser
import EdithKit
import Foundation

struct MachinesThermalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thermal",
        abstract: "Inspect and switch the platform thermal profile.",
        subcommands: [MachinesThermalStatusCommand.self, MachinesThermalSetCommand.self],
        defaultSubcommand: MachinesThermalStatusCommand.self)
}

enum MachineThermalBridge {
    static func status(runner: RemoteRunner) async throws -> MachinePlatformProfile {
        let result = try await runner.run(MachineThermalControls.statusCommand, timeout: 15)
        guard result.succeeded,
            let profile = MachineThermalControls.parseStatus(result.stdoutText)
        else {
            throw CLIFailure.unavailable(
                "\(runner.machine.name) does not expose Linux platform profiles")
        }
        return profile
    }
}

struct MachinesThermalStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show the active and available thermal profiles.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let profile = try await MachineThermalBridge.status(runner: runner)
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "current": .string(profile.current),
                        "choices": .strings(profile.choices),
                    ]))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["MACHINE", "CURRENT", "AVAILABLE"],
                    rows: [
                        [
                            runner.machine.name, profile.current,
                            profile.choices.joined(separator: ", "),
                        ]
                    ]))
        }
    }
}

struct MachinesThermalSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Switch the thermal profile permanently or for a while.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Revert after this many minutes. Zero keeps the profile until changed.")
    var minutes = 0

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "A profile exposed by the machine, such as quiet, balanced or performance.")
    var profile: String

    func run() async throws {
        try await execute {
            guard minutes >= 0, minutes <= 10_080 else {
                throw CLIFailure.usage(
                    "--minutes must be between 0 and 10080",
                    hint: "zero keeps the profile until it is changed again")
            }
            let runner = try await MachineResolver.runner(machine)
            let available = try await MachineThermalBridge.status(runner: runner)
            guard available.choices.contains(profile) else {
                throw CLIFailure.notFound(
                    "\(runner.machine.name) has no thermal profile named \(profile)",
                    hint: "profiles: " + available.choices.joined(separator: ", "))
            }
            let stdin = SudoPassword.stdin(machineID: runner.machine.id)
            guard
                let command = MachineThermalControls.setProfile(
                    profile, durationSeconds: minutes * 60, withSudoPassword: stdin != nil)
            else {
                throw CLIFailure("could not build a safe profile command")
            }
            let result = try await runner.run(command, stdin: stdin, timeout: 30)
            let detail = result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded else {
                throw CLIFailure(
                    "could not switch \(runner.machine.name) to \(profile)"
                        + (detail.isEmpty ? "" : ": \(detail)"),
                    hint: SudoPassword.hint(forRefusal: detail))
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "profile": .string(profile),
                        "temporary": .bool(minutes > 0),
                        "minutes": .int(minutes),
                    ]))
                return
            }
            CLIOut.out(
                minutes > 0
                    ? "switched \(runner.machine.name) to \(profile) for \(minutes) minutes"
                    : "switched \(runner.machine.name) to \(profile) until changed")
        }
    }
}
