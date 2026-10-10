import ArgumentParser
import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

struct StudioCaptionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "captions", abstract: "Edit captions on the rendered output clock.",
        discussion: """
            [Back to the CLI reference](../README.md).

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed studio edit captions list web
            """,
        subcommands: [
            StudioCaptionList.self, StudioCaptionAdd.self, StudioCaptionUpdate.self,
            StudioCaptionRemove.self,
        ], defaultSubcommand: StudioCaptionList.self)
}

struct StudioCaptionOptions: ParsableArguments {
    @Flag(help: "Emit JSON runtime errors. Results are always JSON.") var json = false
    @Flag(help: "Validate without changing the project.") var dryRun = false
}

struct StudioCaptionTiming: ParsableArguments {
    @Option(help: "Inclusive nonnegative output frame; excludes the start-marker option.")
    var startFrame: Int64?
    @Option(help: "Exclusive output frame; excludes the end-marker option.") var endFrame: Int64?
    @Option(help: "Snapshot this marker's exact start position.") var startMarker: String?
    @Option(help: "Snapshot this marker's exact end position.") var endMarker: String?
    @Option(
        help:
            "Frame rate: project, an integer, or numerator/denominator. Required for frame updates."
    ) var fps: String?

    func boundary(frame: Int64?, marker: String?) throws -> VideoEditorService.CaptionBoundary? {
        guard frame == nil || marker == nil else {
            throw VideoEditorService.Failure(
                "invalid_caption", "Choose a frame or marker for each boundary, not both.")
        }
        if let frame { return .frame(frame) }
        if let marker { return .marker(marker) }
        return nil
    }

    func rate(defaultProject: Bool = false) throws -> VideoEditorService.CaptionRate? {
        guard let fps else { return defaultProject ? .project : nil }
        if fps == "project" { return .project }
        let pieces = fps.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), let numerator = Int(pieces[0]),
            let denominator = pieces.count == 2 ? Int(pieces[1]) : 1
        else {
            throw VideoEditorService.Failure(
                "invalid_caption", "FPS must be project, an integer, or numerator/denominator.")
        }
        do {
            return .explicit(
                try VideoCaptionFrameRate(numerator: numerator, denominator: denominator))
        } catch { throw VideoEditorService.Failure("invalid_caption", error.localizedDescription) }
    }
}

enum StudioCaptionBridge {
    static func style(_ path: String?) throws -> VideoCaptionStyle? {
        guard let path else { return nil }
        let url = StudioEditBridge.url(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try VideoCaptionStyle.decode(handle.read(upToCount: 65537) ?? Data())
    }

    static func printReport(_ report: VideoEditorService.CaptionReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        CLIOut.out(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}

struct StudioCaptionList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List stable caption IDs, clocks and exact frame anchors.",
        discussion: """
            List stable caption IDs, clocks and exact frame anchors.

            Reads the saved records in stored order. Does not change them.

            ed studio edit captions list web
            ed studio edit captions list web --json
            """, )
    @Argument(help: "Local .openscreen project.") var project: String
    @Flag(help: "Emit JSON runtime errors. Results are always JSON.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            try StudioCaptionBridge.printReport(
                VideoEditorService.listCaptions(StudioEditBridge.url(project)))
        }
    }
}

struct StudioCaptionAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add an output-anchored caption and return its stable ID.",
        discussion: """
            Add an output-anchored caption and return its stable ID.

            Changes the saved list by adding one record.

            ed studio edit captions add web --text hello
            """, )
    @Argument(help: "Local .openscreen project.") var project: String
    @Option(help: "Caption content, 1 to 10000 UTF-8 bytes.") var text: String
    @Option(help: "Strict caption-style JSON file in reference-canvas pixels; see edit schema.")
    var style: String?
    @OptionGroup var timing: StudioCaptionTiming
    @OptionGroup var options: StudioCaptionOptions

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            guard
                let start = try timing.boundary(
                    frame: timing.startFrame, marker: timing.startMarker),
                let end = try timing.boundary(frame: timing.endFrame, marker: timing.endMarker)
            else {
                throw VideoEditorService.Failure(
                    "invalid_caption", "Both start and end boundaries are required.")
            }
            let report = try await VideoEditorService.changeCaption(
                .add(
                    content: text, start: start, end: end, rate: timing.rate(defaultProject: true)!,
                    style: StudioCaptionBridge.style(style)),
                in: StudioEditBridge.url(project), dryRun: options.dryRun)
            try StudioCaptionBridge.printReport(report)
        }
    }
}

struct StudioCaptionUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update caption text, style or output boundaries by stable ID.",
        discussion: """
            Update caption text, style or output boundaries by stable ID.

            Changes the state this command names.

            ed studio edit captions update web 1
            """, )
    @Argument(help: "Local .openscreen project.") var project: String
    @Argument(help: "Existing caption ID.") var id: String
    @Option(help: "Replacement caption content.") var text: String?
    @Option(help: "Replace the saved caption style using a strict JSON file; timing is preserved.")
    var style: String?
    @OptionGroup var timing: StudioCaptionTiming
    @OptionGroup var options: StudioCaptionOptions

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            let report = try await VideoEditorService.changeCaption(
                .update(
                    id: id, content: text,
                    start: timing.boundary(frame: timing.startFrame, marker: timing.startMarker),
                    end: timing.boundary(frame: timing.endFrame, marker: timing.endMarker),
                    rate: timing.rate(), style: StudioCaptionBridge.style(style)),
                in: StudioEditBridge.url(project), dryRun: options.dryRun)
            try StudioCaptionBridge.printReport(report)
        }
    }
}

struct StudioCaptionRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove one caption by stable ID; unknown IDs fail.",
        discussion: """
            Remove one caption by stable ID; unknown IDs fail.

            Changes the state this command names.

            ed studio edit captions remove web 1
            """, )
    @Argument(help: "Local .openscreen project.") var project: String
    @Argument(help: "Existing caption ID.") var id: String
    @OptionGroup var options: StudioCaptionOptions

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            let report = try await VideoEditorService.changeCaption(
                .remove(id: id), in: StudioEditBridge.url(project), dryRun: options.dryRun)
            try StudioCaptionBridge.printReport(report)
        }
    }
}
