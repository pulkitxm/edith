import ArgumentParser
import EdithExtensionCommands

struct DatabasePackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack", abstract: "Inspect the downloaded Database driver's ownership.",
        subcommands: [
            DatabasePackStatusCommand.self, DatabasePackInstallCommand.self,
            DatabasePackRemoveCommand.self,
        ], defaultSubcommand: DatabasePackStatusCommand.self)
}

struct DatabasePackStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Report the active extension-owned database drivers.")
    @Flag(name: .long, help: "Emit one JSON object on stdout.") var json = false

    func run() async throws {
        if json {
            CLIOut.json(
                .object([
                    "state": .string("active"), "owner": .string("database"),
                    "managementCommand": .string("ed extensions info database"),
                ]))
        } else {
            CLIOut.out("database drivers are owned by the active Database extension")
            CLIOut.out("inspect: ed extensions info database")
        }
    }
}

struct DatabasePackInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Show the marketplace command for Database drivers.")
    @Flag(name: .long, help: "Emit one JSON object on stdout.") var json = false

    func run() async throws {
        throw CLIFailure.usage(
            "Database drivers are installed with the extension",
            hint: "run `ed extensions install database` or `ed extensions update database`")
    }
}

struct DatabasePackRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Show the marketplace command to remove Database drivers.")
    @Flag(name: .long, help: "Emit one JSON object on stdout.") var json = false

    func run() async throws {
        throw CLIFailure.usage(
            "Database drivers are removed with the extension",
            hint: "run `ed extensions remove database`")
    }
}
