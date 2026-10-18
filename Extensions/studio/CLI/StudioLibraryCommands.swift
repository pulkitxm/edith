import ArgumentParser
import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

struct StudioLibraryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library",
        abstract: "Show manage Studio's media list without opening the app.",
        discussion: """
            Removing or clearing media leaves source files and saved projects untouched.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed studio library list
            """,
        subcommands: [
            StudioLibraryListCommand.self, StudioLibraryAddCommand.self,
            StudioLibraryRemoveCommand.self, StudioLibraryClearCommand.self,
        ],
        defaultSubcommand: StudioLibraryListCommand.self)
}

enum StudioLibraryOutput {
    static func print(_ items: [StudioMediaItem], json: Bool) {
        if json {
            CLIOut.json(
                .array(
                    items.map { item in
                        .object([
                            "path": .string(item.url.path), "name": .string(item.name),
                            "addedAt": .string(ISO8601DateFormatter().string(from: item.addedAt)),
                            "exists": .bool(FileManager.default.fileExists(atPath: item.url.path)),
                        ])
                    }))
        } else {
            for item in items { CLIOut.out(item.url.path) }
        }
    }
}

struct StudioLibraryListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List media references, including missing files.",
        discussion: """
            List media references, including missing files.

            Reads the saved records in stored order. Does not change them.

            ed studio library list
            ed studio library list --json
            """, aliases: ["ls"])
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() async throws {
        try await execute {
            StudioLibraryOutput.print(
                try StudioMediaLibrary.list(defaults: StudioCLIEnvironment.defaults), json: json)
        }
    }
}

struct StudioLibraryAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add files or folders to the media list.",
        discussion: """
            Add files or folders to the media list.

            Changes the saved list by adding one record.

            ed studio library add /home/pi/notes.txt /var/backups
            ed studio library add /home/pi/notes.txt /var/backups --json
            """, )
    @Argument(help: "Files or folders to add.") var paths: [String]
    @Flag(name: .long, help: "Emit the updated list as JSON.") var json = false
    func run() async throws {
        try await execute {
            guard !paths.isEmpty else { throw CLIFailure.usage("provide at least one path") }
            StudioLibraryOutput.print(
                try StudioMediaLibrary.add(
                    StudioBridge.files(paths), defaults: StudioCLIEnvironment.defaults), json: json)
        }
    }
}

struct StudioLibraryRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove references without deleting files.",
        discussion: """
            Remove references without deleting files.

            Changes the state this command names.

            ed studio library remove /home/pi/notes.txt /var/backups
            ed studio library remove /home/pi/notes.txt /var/backups --json
            """, aliases: ["rm"])
    @Argument(help: "Paths to remove, including missing files.") var paths: [String]
    @Flag(name: .long, help: "Emit the updated list as JSON.") var json = false
    func run() async throws {
        try await execute {
            guard !paths.isEmpty else { throw CLIFailure.usage("provide at least one path") }
            let urls = Set(
                paths.map {
                    StudioCLIEnvironment.url($0)
                })
            StudioLibraryOutput.print(
                try StudioMediaLibrary.remove(urls, defaults: StudioCLIEnvironment.defaults),
                json: json)
        }
    }
}

struct StudioLibraryClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear media references while preserving files and saved projects.",
        discussion: """
            Clear media references while preserving files and saved projects.

            Changes the state this command names.

            ed studio library clear
            ed studio library clear --json
            """, )
    @Flag(name: .long, help: "Also clear recent tool-run history.") var recent = false
    @Flag(name: .long, help: "Emit the empty list as JSON.") var json = false
    func run() async throws {
        try await execute {
            try StudioMediaLibrary.clear(defaults: StudioCLIEnvironment.defaults, recent: recent)
            StudioLibraryOutput.print([], json: json)
        }
    }
}
