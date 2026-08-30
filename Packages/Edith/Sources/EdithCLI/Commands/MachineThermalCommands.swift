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
        guard await runner.ssh.remotePlatform != .windows else {
            throw CLIFailure.unavailable(
                "Windows does not expose Linux platform thermal profiles")
        }
        let result = await MachineThermalOperationExecution.status { command, _, timeout in
            do {
                let output = try await runner.run(command, timeout: timeout)
                guard output.succeeded else {
                    return .failure(MachineThermalOperationError.unavailable)
                }
                return .success(output.stdoutText)
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case let .success(profile):
            return profile
        case .failure(MachineThermalOperationError.unavailable):
            throw CLIFailure.unavailable(
                "\(runner.machine.name) does not expose Linux platform profiles")
        case let .failure(error):
            throw error
        }
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
            let result = await MachineThermalOperationExecution.set(
                profile: profile, durationSeconds: minutes * 60,
                machineID: runner.machine.id
            ) { command, stdin, timeout in
                do {
                    let output = try await runner.run(
                        command, stdin: stdin, timeout: timeout)
                    let detail = output.combinedText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    guard output.succeeded else {
                        return .failure(
                            CLIFailure(
                                "could not switch \(runner.machine.name) to \(profile)"
                                    + (detail.isEmpty ? "" : ": \(detail)"),
                                hint: SudoPassword.hint(forRefusal: detail)))
                    }
                    return .success(output.stdoutText)
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case .success:
                break
            case .failure(MachineThermalOperationError.invalidProfile(_)):
                throw CLIFailure("could not build a safe profile command")
            case let .failure(error):
                throw error
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
