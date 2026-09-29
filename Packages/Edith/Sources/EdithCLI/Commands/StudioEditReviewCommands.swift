import ArgumentParser
import Edith
import Foundation

struct StudioEditList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List native project files in a directory.")
    @Argument(help: "Directory containing .openscreen projects.") var directory: String
    @Flag(help: "Emit JSON results and runtime errors.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            let projects = try VideoEditorService.list(in: StudioEditBridge.url(directory))
            if json {
                try StudioEditBridge.printJSON(projects)
            } else {
                for project in projects {
                    CLIOut.out("\(project.path): \(project.title ?? project.error ?? "Unreadable")")
                }
            }
        }
    }
}

struct StudioEditClone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone", abstract: "Copy an edit with a fresh project identity and title.")
    @Argument var project: String
    @Option(help: "Destination .openscreen file.") var output: String
    @Option(help: "New project title.") var title: String
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            let result = try VideoEditorService.clone(
                StudioEditBridge.url(project), to: StudioEditBridge.url(output), title: title,
                overwrite: options.overwrite)
            try StudioEditBridge.printResult(result, json: options.json)
        }
    }
}

struct StudioEditContactSheet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contact-sheet", abstract: "Render a labeled PNG grid of output frames.")
    @Argument var project: String
    @Option(help: "Output seconds, one --time for each frame (maximum 64).") var time: [Double]
    @Option(help: "Number of columns, from 1 to 8.") var columns = 4
    @Option(help: "Maximum thumbnail dimension in pixels, from 64 to 1920.") var cellWidth = 320
    @Option(help: "Destination .png file.") var output: String
    @Flag(help: "Append saved manual and transient markers on an output-time strip.")
    var showBeatMarkers = false
    @Option(
        help: "Audio/video asset or audio track ID for a waveform; requires all four mapping options.")
    var waveformAsset: String?
    @Option(help: "Waveform source-range start in seconds.") var sourceIn: Double?
    @Option(help: "Waveform source-range end in seconds (exclusive).") var sourceOut: Double?
    @Option(help: "Output offset in seconds for the waveform source-range start.") var outputStart:
        Double?
    @Option(help: "Waveform source-to-output rate, from 0.05 to 20.") var playbackRate: Double?
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            var overlays = VideoEditorService.ReviewOverlays()
            overlays.showBeatMarkers = showBeatMarkers
            overlays.waveformAssetID = waveformAsset
            if [sourceIn, sourceOut, outputStart, playbackRate].contains(where: { $0 != nil }) {
                guard let sourceIn, let sourceOut, let outputStart, let playbackRate else {
                    throw VideoEditorService.Failure(
                        "invalid_mapping",
                        "Supply --source-in, --source-out, --output-start and --playback-rate together."
                    )
                }
                overlays.waveformMapping = .init(
                    sourceInSeconds: sourceIn, sourceOutSeconds: sourceOut,
                    outputStartSeconds: outputStart, playbackRate: playbackRate)
            }
            let result = try await VideoEditorService.contactSheet(
                StudioEditBridge.url(project), times: time, columns: columns, cellWidth: cellWidth,
                to: StudioEditBridge.url(output), overwrite: options.overwrite, overlays: overlays)
            if options.json {
                try StudioEditBridge.printJSON(result)
            } else {
                CLIOut.out("saved: \(result.path)")
                CLIOut.out("\(result.frames.count) frames, \(result.width) x \(result.height)")
            }
        }
    }
}

extension StudioEditBridge {
    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        CLIOut.out(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
