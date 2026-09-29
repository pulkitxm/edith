import ArgumentParser
import Edith
import Foundation

struct StudioEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit and render native video projects without opening a window.",
        discussion:
            "Use schema for the versioned edit-plan format. Apply validates the entire plan before saving. Media stays local.",
        subcommands: [
            StudioEditSchema.self, StudioEditCreate.self, StudioEditShow.self,
            StudioEditApply.self, StudioEditValidate.self, StudioEditRender.self,
            StudioEditFrame.self, StudioEditRenderAudio.self, StudioEditList.self,
            StudioEditClone.self,
            StudioEditContactSheet.self, StudioEditMediaCommand.self,
            StudioMarkerCommand.self, StudioEditAudio.self,
        ], defaultSubcommand: StudioEditSchema.self)
}

struct StudioEditOutput: ParsableArguments {
    @Flag(help: "Emit JSON results and runtime errors.") var json = false
    @Flag(help: "Replace an existing destination atomically.") var overwrite = false
}

enum StudioEditBridge {
    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func run(json: Bool, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            let interrupted = error as? StudioEditInterrupted
            let code =
                interrupted != nil
                ? "cancelled"
                : (error as? VideoEditorService.Failure)?.code ?? "edit_failed"
            if json {
                let data = try JSONSerialization.data(
                    withJSONObject: [
                        "version": 1,
                        "error": ["code": code, "message": error.localizedDescription],
                    ], options: [.sortedKeys])
                CLIOut.note(String(decoding: data, as: UTF8.self))
            } else {
                CLIOut.note("error: " + error.localizedDescription)
            }
            throw ExitCode(
                interrupted.map { 128 + $0.signal } ?? (code.hasPrefix("invalid_") ? 2 : 1))
        }
    }

    static func printResult(_ result: VideoEditorService.Result, json: Bool) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            CLIOut.out(String(decoding: try encoder.encode(result), as: UTF8.self))
        } else {
            CLIOut.out("\(result.written ? "saved" : "validated"): \(result.path)")
            for name in result.aliases.keys.sorted() {
                CLIOut.out("\(name): \(result.aliases[name]!)")
            }
        }
    }
}

struct StudioEditSchema: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema", abstract: "Print the edit-plan JSON Schema.")
    @Flag(help: "Emit JSON runtime errors. The schema is always JSON.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            CLIOut.out(String(decoding: try VideoEditPlan.schema(), as: UTF8.self))
        }
    }
}

struct StudioEditCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Create an empty .openscreen project.")
    @Argument(help: "Destination .openscreen file.") var project: String
    @Option(help: "Project title.") var title = "Untitled video"
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            try StudioEditBridge.printResult(
                VideoEditorService.create(
                    at: StudioEditBridge.url(project), title: title, overwrite: options.overwrite),
                json: options.json)
        }
    }
}

struct StudioEditShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Print project JSON, including IDs for subsequent edits.")
    @Argument var project: String
    @Flag(help: "Emit JSON runtime errors. The project is always JSON.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            CLIOut.out(
                String(
                    decoding: try VideoEditorService.show(StudioEditBridge.url(project)),
                    as: UTF8.self))
        }
    }
}

struct StudioEditApply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply", abstract: "Validate and atomically apply a version 1 edit plan.")
    @Argument var project: String
    @Option(help: "JSON edit-plan file. Relative media paths resolve beside this file.") var plan:
        String
    @Option(help: "Save a new project instead of replacing the input.") var output: String?
    @Flag(help: "Validate every operation and source without writing any files.") var dryRun = false
    @OptionGroup var options: StudioEditOutput

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            let planURL = StudioEditBridge.url(plan)
            let size = try planURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= 4 * 1024 * 1024
            else {
                throw VideoEditorService.Failure(
                    "invalid_plan", "Expected a regular edit-plan file of at most 4 MiB.")
            }
            let edit = try VideoEditPlan.decode(Data(contentsOf: planURL))
            let result = try await VideoEditorService.apply(
                edit, to: StudioEditBridge.url(project), output: output.map(StudioEditBridge.url),
                dryRun: dryRun, overwrite: options.overwrite,
                mediaDirectory: planURL.deletingLastPathComponent())
            try StudioEditBridge.printResult(result, json: options.json)
        }
    }
}

struct StudioEditValidate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Check project structure, local media and native composition.")
    @Argument var project: String
    @Flag(help: "Emit JSON results and runtime errors.") var json = false

    func run() async throws {
        try await StudioEditBridge.run(json: json) {
            let result = try await VideoEditorService.validate(StudioEditBridge.url(project))
            try StudioEditBridge.printResult(result, json: json)
        }
    }
}

struct StudioEditFrame: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frame", abstract: "Render one composited frame as PNG.")
    @Argument var project: String
    @Option(help: "Output seconds, snapped to the preceding output frame; excludes --frame.")
    var time: Double?
    @Option(help: "Exact zero-based output frame index; excludes --time.") var frame: Int64?
    @Option(help: "Destination .png file.") var output: String
    @OptionGroup var options: StudioEditOutput

    func validate() throws {
        guard (time != nil) != (frame != nil) else {
            throw ValidationError("Choose exactly one of --time or --frame.")
        }
    }

    func run() async throws {
        try await StudioEditBridge.run(json: options.json) {
            let result = try await VideoEditorService.frame(
                StudioEditBridge.url(project), at: time, frameIndex: frame,
                to: StudioEditBridge.url(output),
                overwrite: options.overwrite)
            try StudioEditBridge.printResult(result, json: options.json)
        }
    }
}
