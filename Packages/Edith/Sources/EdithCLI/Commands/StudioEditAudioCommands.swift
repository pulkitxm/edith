import ArgumentParser
import Edith
import EdithStudio
import Foundation

struct StudioAudioHealth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Report detected FFmpeg loudnorm availability and engine version.",
        discussion: """
            Report detected FFmpeg loudnorm availability and engine version.

            Reads the current state. Does not change it.

            ed studio edit audio health
            ed studio edit audio health --json
            """, )
    @Flag(help: "Emit JSON results.") var json = false
    func run() async throws {
        try StudioAudioOutput.emit(await StudioAudioMastering.health())
    }
}

struct StudioAudioMeasure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "measure",
        abstract: "Measure integrated LUFS, loudness range and true peak using FFmpeg loudnorm.",
        discussion: """
            Measure integrated LUFS, loudness range and true peak using FFmpeg loudnorm.

            Reads the current state. Does not change it.

            ed studio edit audio measure web --asset asset
            ed studio edit audio measure web --asset asset --json
            """, )
    @Argument(help: "Local .openscreen project.") var project: String
    @Option(
        help: "Project audio/video asset or independent track ID; uses its processed reference.")
    var asset: String
    @Flag(help: "Emit JSON results and errors.") var json = false
    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            let result = try await StudioEditExecution.run(progress: false, json: json) { _ in
                try await VideoEditorService.measureAudio(
                    StudioEditBridge.url(project), assetID: asset)
            }
            try StudioAudioOutput.emit(result)
        }
    }
}

struct StudioAudioMaster: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "master",
        abstract: "Create an immutable verified soundtrack and an editable project copy.",
        discussion:
            """
            Requires FFmpeg loudnorm. Reads the track's original source from zero, trims
            exactly, applies a 0.25-second final fade and two-pass -16 LUFS/-1.5
            dBTP/LRA 11 mastering. The new bundle contains soundtrack.wav, report.json
            and project.openscreen. Only the selected track in the copy is replaced,
            with unity gain, no loops and output start zero. Existing destinations are
            refused.

            ed studio edit audio master web --track track --duration 0.5 --output /tmp/out.png
            ed studio edit audio master web --track track --duration 0.5 --output /tmp/out.png --json
            """
    )
    @Argument(help: "Local .openscreen project.") var project: String
    @Option(help: "Independent soundtrack track ID to replace in the new project copy.") var track:
        String
    @Option(help: "Exact duration in seconds, aligned to a 48000 Hz sample.") var duration: Double
    @Option(help: "New bundle directory; must not exist.") var output: String
    @Flag(help: "Emit JSON results and errors.") var json = false
    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            let result = try await StudioEditExecution.run(progress: false, json: json) { _ in
                try await VideoEditorService.masterAudio(
                    StudioEditBridge.url(project), trackID: track,
                    to: StudioEditBridge.url(output), request: .init(durationSeconds: duration))
            }
            try StudioAudioOutput.emit(result)
        }
    }
}

enum StudioAudioOutput {
    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        CLIOut.out(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
