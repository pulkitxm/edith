import ArgumentParser
import EdithKit
import Foundation

struct StudioLibraryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library", abstract: "Manage Studio's media list without opening the app.",
        discussion: "Removing or clearing media leaves source files and saved projects untouched.",
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
        abstract: "List media references, including missing files.", aliases: ["ls"])
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() async throws {
        try await execute {
            StudioLibraryOutput.print(
                try StudioMediaLibrary.list(defaults: CLIEnvironment.sharedDefaults), json: json)
        }
    }
}

struct StudioLibraryAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add files or folders to the media list.")
    @Argument(help: "Files or folders to add.") var paths: [String]
    @Flag(name: .long, help: "Emit the updated list as JSON.") var json = false
    func run() async throws {
        try await execute {
            guard !paths.isEmpty else { throw CLIFailure.usage("provide at least one path") }
            StudioLibraryOutput.print(
                try StudioMediaLibrary.add(
                    StudioBridge.files(paths), defaults: CLIEnvironment.sharedDefaults), json: json)
        }
    }
}

struct StudioLibraryRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove references without deleting files.", aliases: ["rm"])
    @Argument(help: "Paths to remove, including missing files.") var paths: [String]
    @Flag(name: .long, help: "Emit the updated list as JSON.") var json = false
    func run() async throws {
        try await execute {
            guard !paths.isEmpty else { throw CLIFailure.usage("provide at least one path") }
            let urls = Set(
                paths.map {
                    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
                })
            StudioLibraryOutput.print(
                try StudioMediaLibrary.remove(urls, defaults: CLIEnvironment.sharedDefaults),
                json: json)
        }
    }
}

struct StudioLibraryClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear media references while preserving files and saved projects.")
    @Flag(name: .long, help: "Also clear recent tool-run history.") var recent = false
    @Flag(name: .long, help: "Emit the empty list as JSON.") var json = false
    func run() async throws {
        try await execute {
            try StudioMediaLibrary.clear(defaults: CLIEnvironment.sharedDefaults, recent: recent)
            StudioLibraryOutput.print([], json: json)
        }
    }
}
