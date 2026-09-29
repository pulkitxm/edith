import ArgumentParser
import Edith
import Foundation

struct StudioEditMediaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "media",
        abstract: "Inspect original media and maintain verified project identities.",
        subcommands: [
            StudioMediaIdentity.self, StudioMediaProbe.self, StudioMediaDuplicates.self,
            StudioMediaChronology.self, StudioMediaIndex.self, StudioMediaProvenance.self,
            StudioMediaUsage.self,
            StudioMediaPackage.self, StudioMediaOpen.self, StudioMediaRelink.self,
        ], defaultSubcommand: StudioMediaIdentity.self)
}

struct StudioMediaReadOptions: ParsableArguments {
    @Flag(help: "Emit JSON errors. Results are always typed JSON envelopes.") var json = false
}

struct StudioMediaWriteOptions: ParsableArguments {
    @Option(help: "Write a new .openscreen project instead of the input.") var output: String?
    @Flag(help: "Validate the mutation without writing a project.") var dryRun = false
    @Flag(help: "Replace an existing project with revision validation.") var overwrite = false
    @Flag(help: "Emit JSON errors. Results are always typed JSON envelopes.") var json = false
}

enum StudioMediaBridge {
    static func run(json: Bool, _ operation: () async throws -> Data) async throws {
        try await StudioEditBridge.run(json: json) {
            CLIOut.out(String(decoding: try await operation(), as: UTF8.self))
        }
    }
}

struct StudioMediaIdentity: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity", abstract: "Stream an exact SHA-256 media identity.")
    @Argument(help: "Local media file.") var path: String
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaIdentity(StudioEditBridge.url(path))
        }
    }
}

struct StudioMediaUsage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage",
        abstract: "Audit every clip occurrence for within-cut and cross-project original reuse.")
    @Option(help: "Local project path; repeat for each project, up to 100.") var project: [String]
    @Option(help: "visual excludes independent audio; all includes music and audio tracks.")
    var scope = "visual"
    @Option(help: "Stable occurrence and conflict offset, 0 to 10000.") var offset = 0
    @Option(help: "Maximum rows per collection, 1 to 100.") var limit = 100
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaUsage(
                projects: project.map(StudioEditBridge.url), scope: scope, offset: offset,
                limit: limit)
        }
    }
}

struct StudioMediaProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe", abstract: "Inspect actual formats and capture-date certainty.")
    @Argument(help: "Local media file.") var path: String
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaProbe(StudioEditBridge.url(path))
        }
    }
}

struct StudioMediaDuplicates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicates",
        abstract: "Find byte-identical copies across 2 to 1000 local paths.")
    @Argument(help: "Local files to compare.") var paths: [String]
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaDuplicates(paths.map(StudioEditBridge.url))
        }
    }
}

struct StudioMediaChronology: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chronology",
        abstract: "Order up to 1000 files by normalized capture time; unknown dates sort last.")
    @Argument(help: "Local media files.") var paths: [String]
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaChronology(paths.map(StudioEditBridge.url))
        }
    }
}

struct StudioMediaIndex: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index", abstract: "Record verified media identities in a project.")
    @Argument(help: "Source .openscreen project.") var project: String
    @Flag(help: "Also probe codec, dimensions, audio format and capture metadata.") var probe =
        false
    @OptionGroup var options: StudioMediaWriteOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaIndex(
                StudioEditBridge.url(project), probe: probe,
                output: options.output.map(StudioEditBridge.url), dryRun: options.dryRun,
                overwrite: options.overwrite)
        }
    }
}

struct StudioMediaProvenance: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provenance",
        abstract: "Declare a shared source family for alternate exports explicitly.")
    @Argument(help: "Source .openscreen project.") var project: String
    @Option(help: "Original asset ID, up to 1000 characters.") var asset: String
    @Option(help: "Shared source family ID, up to 1000 characters.") var family: String
    @Option(help: "Explicit provenance declaration, up to 4000 characters.") var declaration: String
    @OptionGroup var options: StudioMediaWriteOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaProvenance(
                StudioEditBridge.url(project), assetID: asset,
                familyID: family, declaration: declaration,
                output: options.output.map(StudioEditBridge.url),
                dryRun: options.dryRun, overwrite: options.overwrite)
        }
    }
}
