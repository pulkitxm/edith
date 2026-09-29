import ArgumentParser
import Edith
import Foundation

struct StudioEditPublications: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publications",
        abstract: "Manage upload order separately from project identity and edits.",
        discussion:
            "Version 1 JSON manifests contain an ordered items array of projectID, projectPath and title. No project files are written. Show validates references and identities.",
        subcommands: [
            StudioPublicationCreate.self, StudioPublicationShow.self, StudioPublicationReorder.self,
        ], defaultSubcommand: StudioPublicationShow.self)
}

enum StudioPublicationOutput {
    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        CLIOut.out(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

struct StudioPublicationCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a version 1 publication manifest from a project list.",
        discussion:
            "Input: {\"version\":1,\"projects\":[{\"path\":\"cut.openscreen\",\"title\":\"Optional upload title\"}]}. Relative project paths resolve beside the input plan. Stored paths are absolute. Up to 100 projects and 1 MiB of JSON. Unknown fields are rejected."
    )
    @Argument(help: "Destination .json manifest.") var manifest: String
    @Option(help: "Version 1 JSON project-list plan.") var input: String
    @Flag(help: "Validate and preview without writing files.") var dryRun = false
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            try StudioPublicationOutput.printJSON(
                await VideoPublicationService.create(
                    at: StudioEditBridge.url(manifest), input: StudioEditBridge.url(input),
                    dryRun: dryRun, overwrite: options.overwrite))
        }
    }
}

struct StudioPublicationShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Validate a manifest and print its ordered project references.",
        discussion:
            "Checks project identities, duplicate projects and missing project/dependency files. Relative projectPath values resolve beside the manifest. Does not validate render quality or reserve source reuse."
    )
    @Argument(help: "Version 1 .json manifest.") var manifest: String
    @Flag(help: "Emit JSON runtime errors. Output is always JSON.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            try StudioPublicationOutput.printJSON(
                VideoPublicationService.show(StudioEditBridge.url(manifest)))
        }
    }
}

struct StudioPublicationReorder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reorder",
        abstract: "Atomically replace manifest order using stable project IDs.",
        discussion:
            "Input: {\"version\":1,\"projectIDs\":[\"second-project-id\",\"approved-project-id\"]}. Supply every current project ID exactly once. Only the manifest array changes; titles, paths and project bytes stay unchanged. Requires --overwrite, including with --dry-run."
    )
    @Argument(help: "Existing .json manifest to reorder.") var manifest: String
    @Option(help: "Version 1 JSON order plan.") var input: String
    @Flag(help: "Validate and preview without writing files.") var dryRun = false
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            try StudioPublicationOutput.printJSON(
                await VideoPublicationService.reorder(
                    StudioEditBridge.url(manifest), input: StudioEditBridge.url(input),
                    dryRun: dryRun, overwrite: options.overwrite))
        }
    }
}
