import ArgumentParser
import Edith
import Foundation

struct StudioMarkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markers", abstract: "Inspect and transactionally edit output-frame markers.",
        discussion: """
            [Back to `ed studio`](./README.md) · [All CLI commands](../README.md).

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed studio edit markers list
            """,
        subcommands: [
            StudioMarkerList.self, StudioMarkerAdd.self, StudioMarkerUpdate.self,
            StudioMarkerRemove.self, StudioMarkerImport.self, StudioMarkerExport.self,
            StudioMarkerSnap.self,
        ], defaultSubcommand: StudioMarkerList.self)
}

struct StudioMarkerTarget: ParsableArguments {
    @Argument(help: "Local .openscreen project.") var project: String
    @Flag(help: "Emit structured runtime errors. Results are always typed JSON.") var json = false
    var url: URL { StudioEditBridge.url(project) }

    func emit<T: Encodable>(_ body: () async throws -> T) async throws {
        try await StudioEditBridge.run(json: json) {
            let result = try await body()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(result)
            guard data.count <= 4 << 20 else {
                throw VideoEditorService.Failure(
                    "result_too_large", "JSON result exceeds 4 MiB; export markers to a file.")
            }
            CLIOut.out(String(decoding: data, as: UTF8.self))
        }
    }
}

struct StudioMarkerFPS: ParsableArguments {
    @Option(help: "Explicit output FPS as NUMERATOR/DENOMINATOR, or an integer.") var fps: String?
    @Flag(help: "Use validated saved project FPS, otherwise the native composition FPS.")
    var projectFps = false

    func selection(required: Bool = true) throws -> VideoEditorService.MarkerRate? {
        guard !(fps != nil && projectFps) else {
            throw VideoEditorService.Failure(
                "invalid_frame_rate", "Choose --fps or --project-fps, not both.")
        }
        if projectFps { return .project }
        if let fps {
            let parts = fps.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let numerator = Int(parts[0]),
                let denominator = parts.count == 2 ? Int(parts[1]) : 1
            else {
                throw VideoEditorService.Failure(
                    "invalid_frame_rate", "Use FPS as an integer or NUMERATOR/DENOMINATOR.")
            }
            do {
                return .explicit(
                    try VideoMarkerFrameRate(numerator: numerator, denominator: denominator))
            } catch {
                throw VideoEditorService.Failure("invalid_frame_rate", error.localizedDescription)
            }
        }
        if required {
            throw VideoEditorService.Failure(
                "invalid_frame_rate", "Specify --fps or --project-fps.")
        }
        return nil
    }

    func required() throws -> VideoEditorService.MarkerRate {
        guard let result = try selection() else {
            throw VideoEditorService.Failure("invalid_frame_rate", "Specify output FPS.")
        }
        return result
    }
}

struct StudioMarkerList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List saved output frames and each marker's rational FPS.",
        discussion: """
            List saved output frames and each marker's rational FPS.

            Reads the saved records in stored order. Does not change them.

            ed studio edit markers list
            """, )
    @OptionGroup var target: StudioMarkerTarget
    func run() async throws {
        try await target.emit { try VideoEditorService.listMarkers(target.url) }
    }
}

struct StudioMarkerAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add one manual marker at an output frame.",
        discussion: """
            Add one manual marker at an output frame.

            Changes the saved list by adding one record.

            ed studio edit markers add --frame 1
            """, )
    @OptionGroup var target: StudioMarkerTarget
    @OptionGroup var rate: StudioMarkerFPS
    @Option(help: "Nonnegative output frame in the selected FPS.") var frame: Int64
    @Option(help: "Marker label.") var label = "Marker"
    @Flag(help: "Validate without publishing project changes.") var dryRun = false
    func run() async throws {
        try await target.emit {
            try await VideoEditorService.changeMarkers(
                .add(frame: frame, rate: rate.required(), label: label), in: target.url,
                dryRun: dryRun)
        }
    }
}

struct StudioMarkerUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a marker by ID; FPS-only changes preserve output time.",
        discussion: """
            Update a marker by ID; FPS-only changes preserve output time.

            Changes the state this command names.

            ed studio edit markers update --id 1
            """, )
    @OptionGroup var target: StudioMarkerTarget
    @OptionGroup var rate: StudioMarkerFPS
    @Option(help: "Existing marker ID.") var id: String
    @Option(help: "New output frame; requires --fps or --project-fps.") var frame: Int64?
    @Option(help: "New marker label.") var label: String?
    @Flag(help: "Validate without publishing project changes.") var dryRun = false
    func run() async throws {
        try await target.emit {
            try await VideoEditorService.changeMarkers(
                .update(
                    id: id, frame: frame, rate: rate.selection(required: frame != nil), label: label
                ), in: target.url, dryRun: dryRun)
        }
    }
}

struct StudioMarkerRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove an existing marker by ID.",
        discussion: """
            Remove an existing marker by ID.

            Changes the state this command names.

            ed studio edit markers remove --id 1
            """, )
    @OptionGroup var target: StudioMarkerTarget
    @Option(help: "Existing marker ID.") var id: String
    @Flag(help: "Validate without publishing project changes.") var dryRun = false
    func run() async throws {
        try await target.emit {
            try await VideoEditorService.changeMarkers(
                .remove(id: id), in: target.url, dryRun: dryRun)
        }
    }
}

struct StudioMarkerImport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a version 1 marker document, validating all entries before publication.",
        discussion: """
            Import a version 1 marker document, validating all entries before
            publication.

            Changes the companion database by restoring a bundle from export.

            ed studio edit markers import --input /tmp/out.png
            """, )
    @OptionGroup var target: StudioMarkerTarget
    @Option(help: "Local JSON document with version and markers, at most 32 MiB.") var input: String
    @Flag(help: "Replace the marker list instead of appending; duplicate IDs are rejected.")
    var replace = false
    @Flag(help: "Validate without publishing project changes.") var dryRun = false
    func run() async throws {
        try await target.emit {
            let url = StudioEditBridge.url(input)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 32 << 20 else {
                throw VideoEditorService.Failure(
                    "invalid_markers", "Expected a regular marker document of at most 32 MiB.")
            }
            return try await VideoEditorService.changeMarkers(
                .importDocument(Data(contentsOf: url), replace: replace), in: target.url,
                dryRun: dryRun)
        }
    }
}

struct StudioMarkerExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a version 1 marker document without replacing project dependencies.",
        discussion: """
            Export a version 1 marker document without replacing project dependencies.

            Reads everything the companion remembers and writes a restorable bundle.

            ed studio edit markers export --output /tmp/out.png
            """, )
    @OptionGroup var target: StudioMarkerTarget
    @Option(help: "Destination .json file.") var output: String
    @Flag(help: "Atomically replace an existing non-dependency destination.") var overwrite = false
    func run() async throws {
        try await target.emit {
            try VideoEditorService.exportMarkers(
                target.url, to: StudioEditBridge.url(output), overwrite: overwrite)
        }
    }
}

struct StudioMarkerSnap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snap",
        abstract:
            "Return the nearest marker within an inclusive output-frame threshold, without writing.",
        discussion: """
            Return the nearest marker within an inclusive output-frame threshold,
            without writing.

            Changes the state this command names.

            ed studio edit markers snap --frame 1
            """, )
    @OptionGroup var target: StudioMarkerTarget
    @OptionGroup var rate: StudioMarkerFPS
    @Option(help: "Requested nonnegative output frame.") var frame: Int64
    @Option(help: "Inclusive threshold in output frames at the selected FPS.") var thresholdFrames:
        Int64 = 3
    func run() async throws {
        try await target.emit {
            try await VideoEditorService.snapMarker(
                target.url, frame: frame, thresholdFrames: thresholdFrames, rate: rate.required())
        }
    }
}

struct StudioEditAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Analyze, measure and master soundtrack sources headlessly.",
        discussion: """
            [Back to `ed studio`](./README.md) · [All CLI commands](../README.md).

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed studio edit audio analyze --asset asset
            """,
        subcommands: [
            StudioAudioAnalyze.self, StudioAudioHealth.self, StudioAudioMeasure.self,
            StudioAudioMaster.self,
        ], defaultSubcommand: StudioAudioAnalyze.self)
}

struct StudioAudioAnalyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract:
            "Measure bounded waveform and transients; tempo is an estimate, not a confirmed beat grid.",
        discussion:
            """
            All mapping times are seconds. Source range and rate map to output =
            output-start + (source - source-in) / playback-rate. Supply all four mapping
            options and an FPS choice together. Audio-track offsets and loops are not
            inferred.

            Reads the current state. Does not change it.

            ed studio edit audio analyze --asset asset
            """
    )
    @OptionGroup var target: StudioMarkerTarget
    @OptionGroup var rate: StudioMarkerFPS
    @Option(
        help:
            "Project audio/video asset ID or audio-track ID; processed source audio takes precedence."
    ) var asset: String
    @Option(help: "Transient sensitivity from 0 to 1.") var sensitivity: Double = 0.5
    @Option(help: "Refractory duration in seconds.") var refractorySeconds: Double = 0.08
    @Option(help: "Minimum transient spacing in seconds.") var minimumSpacingSeconds: Double = 0.15
    @Option(help: "Even waveform bin limit from 2 to 2048.") var maximumWaveformBins = 2048
    @Option(help: "Transient limit from 1 to 10000.") var maximumTransients = 10_000
    @Option(help: "Inclusive source-range start in seconds.") var sourceIn: Double?
    @Option(help: "Exclusive source-range end in seconds, within decoded audio.") var sourceOut:
        Double?
    @Option(help: "Output offset in seconds for the source-range start.") var outputStart: Double?
    @Option(help: "Source-to-output playback rate, from 0.05 to 20.") var playbackRate: Double?
    func run() async throws {
        try await target.emit {
            let mapping: VideoEditorService.AudioMarkerMapping?
            let values = [sourceIn, sourceOut, outputStart, playbackRate]
            if values.allSatisfy({ $0 == nil }) {
                mapping = nil
            } else if let sourceIn, let sourceOut, let outputStart, let playbackRate {
                mapping = .init(
                    sourceInSeconds: sourceIn, sourceOutSeconds: sourceOut,
                    outputStartSeconds: outputStart, playbackRate: playbackRate)
            } else {
                throw VideoEditorService.Failure(
                    "invalid_mapping",
                    "Supply --source-in, --source-out, --output-start and --playback-rate together."
                )
            }
            var options = VideoEditorService.AudioAnalysisOptions()
            options.sensitivity = sensitivity
            options.refractorySeconds = refractorySeconds
            options.minimumSpacingSeconds = minimumSpacingSeconds
            options.maximumWaveformBins = maximumWaveformBins
            options.maximumTransients = maximumTransients
            return try await VideoEditorService.analyzeAudio(
                target.url, assetID: asset, options: options, mapping: mapping,
                rate: rate.selection(required: mapping != nil))
        }
    }
}
