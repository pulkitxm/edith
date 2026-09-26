import ArgumentParser
import EdithKit
import EdithStudio
import Foundation

struct StudioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "studio",
        abstract: "Edit, convert and compress images, PDFs, video, audio and documents.",
        discussion: """
            Studio's tools run on this Mac, straight from the command line. `tools` lists them,
            `info` shows a tool's settings, `run` applies one to files and `probe` describes a
            file. Results are saved next to the originals unless you pass --output-dir.
            """,
        subcommands: [
            StudioToolsCommand.self, StudioInfoCommand.self, StudioRunCommand.self,
            StudioProbeCommand.self,
        ],
        defaultSubcommand: StudioToolsCommand.self)
}

enum StudioBridge {
    static func tool(_ id: String) throws -> StudioTool {
        let needle = id.lowercased()
        if let exact = StudioCatalog.tool(needle) { return exact }
        let matches = StudioCatalog.tools.filter { $0.title.lowercased() == needle }
        if let match = matches.first { return match }
        throw CLIFailure.notFound(
            "no Studio tool called \(id)", hint: "run `ed studio tools` to see every tool id")
    }

    static func kind(_ raw: String) throws -> StudioKind {
        guard let kind = StudioKind(rawValue: raw.lowercased()) else {
            throw CLIFailure.usage(
                "unknown kind \(raw)",
                hint: "kinds: " + StudioKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return kind
    }

    static func environment() -> StudioEnvironment {
        StudioEnvironment.detect(
            path: CLIToolEnvironment.sanitized()["PATH"],
            resolve: { CLIEnvironment.executableNamed($0) })
    }

    static func settings(_ pairs: [String], for tool: StudioTool) throws -> StudioSettings {
        var settings = StudioSettings()
        for pair in pairs {
            guard let separator = pair.firstIndex(of: "=") else {
                throw CLIFailure.usage("--set needs key=value, got \(pair)")
            }
            let key = String(pair[..<separator]).trimmingCharacters(in: .whitespaces)
            let raw = String(pair[pair.index(after: separator)...])
            guard let option = tool.options.first(where: { $0.key == key }) else {
                throw CLIFailure.usage(
                    "\(tool.id) has no setting called \(key)",
                    hint: "settings: " + tool.options.map(\.key).joined(separator: ", "))
            }
            do {
                settings[key] = try option.parse(raw)
            } catch {
                throw CLIFailure.usage(error.localizedDescription)
            }
        }
        return settings
    }

    static func json(_ tool: StudioTool, environment: StudioEnvironment, detailed: Bool)
        -> JSONValue
    {
        var object: [String: JSONValue] = [
            "id": .string(tool.id), "title": .string(tool.title), "summary": .string(tool.summary),
            "family": .string(tool.family.rawValue), "group": .string(tool.group.rawValue),
            "inputs": .array(tool.inputs.map(\.rawValue).sorted().map { .string($0) }),
            "arity": .string(arity(tool.arity)),
            "opensEditor": .bool(tool.style != .run),
            "available": .bool(environment.missing(for: tool).isEmpty),
        ]
        let missing = environment.missing(for: tool).map(\.title)
        if !missing.isEmpty { object["needs"] = .array(missing.map { .string($0) }) }
        if detailed {
            object["options"] = .array(
                tool.options.map { option in
                    var entry: [String: JSONValue] = [
                        "key": .string(option.key), "label": .string(option.label),
                        "type": .string(type(option.kind)),
                        "default": .string(option.defaultValue.display),
                    ]
                    if case let .choice(choices) = option.kind {
                        entry["choices"] = .array(choices.map { .string($0.value) })
                    }
                    if let help = option.help { entry["help"] = .string(help) }
                    return .object(entry)
                })
        }
        return .object(object)
    }

    static func arity(_ arity: StudioArity) -> String {
        switch arity {
        case .each: "each"
        case let .combine(minimum, maximum):
            maximum.map { "combine \(minimum)-\($0)" } ?? "combine \(minimum)+"
        case .none: "none"
        }
    }

    static func type(_ kind: StudioOption.Kind) -> String {
        switch kind {
        case .choice: "choice"
        case .toggle: "bool"
        case .integer: "integer"
        case .number: "number"
        case .percent: "percent"
        case .text, .longText: "text"
        case .password: "password"
        case .color: "color"
        case .pages: "pages"
        case .time: "time"
        case .span: "range"
        case .rect: "rect"
        case .file: "file"
        case .font: "font"
        case .anchor: "position"
        }
    }

    static func requireNoFailures(_ result: StudioRunResult) throws {
        guard !result.failures.isEmpty else { return }
        let count = result.failures.count
        throw CLIFailure("\(count) file\(count == 1 ? "" : "s") could not be processed")
    }

    static func files(_ paths: [String]) throws -> [URL] {
        try paths.map { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIFailure.notFound("no file at \(path)")
            }
            return url
        }
    }
}

struct StudioToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools", abstract: "List Studio's tools.", aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Only tools for this kind of file: pdf, image, video, audio, document…")
    var kind: String?

    func run() async throws {
        try await execute {
            let environment = StudioBridge.environment()
            var tools = StudioCatalog.tools
            if let kind {
                let filter = try StudioBridge.kind(kind)
                tools = tools.filter { $0.accepts(kind: filter) || $0.family == filter }
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        tools.map {
                            StudioBridge.json($0, environment: environment, detailed: false)
                        }))
                return
            }
            let width = tools.map(\.id.count).max() ?? 10
            for tool in tools {
                let missing = environment.missing(for: tool).map(\.title)
                let suffix =
                    missing.isEmpty
                    ? "" : CLIStyle.dim("  needs " + missing.joined(separator: ", "))
                let padded = tool.id.padding(toLength: width, withPad: " ", startingAt: 0)
                CLIOut.out("\(padded)  \(tool.title)\(suffix)")
            }
        }
    }
}

struct StudioInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info", abstract: "Show what a Studio tool does and its settings.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The tool id, for example pdf.compress.")
    var tool: String

    func run() async throws {
        try await execute {
            let tool = try StudioBridge.tool(self.tool)
            let environment = StudioBridge.environment()
            guard !json else {
                CLIOut.json(StudioBridge.json(tool, environment: environment, detailed: true))
                return
            }
            CLIOut.out(CLIStyle.bold(tool.title) + "  " + CLIStyle.dim(tool.id))
            CLIOut.out(tool.summary)
            CLIOut.out(
                "accepts: " + tool.inputs.map(\.rawValue).sorted().joined(separator: ", ")
                    + " · files: " + StudioBridge.arity(tool.arity))
            if tool.style != .run {
                CLIOut.out(CLIStyle.dim("opens an editor in the Studio window"))
            }
            for option in tool.options {
                var line = "  --set \(option.key)=… (\(StudioBridge.type(option.kind)))"
                line +=
                    "  default \(option.defaultValue.display.isEmpty ? "empty" : option.defaultValue.display)"
                if case let .choice(choices) = option.kind {
                    line += "  one of " + choices.map(\.value).joined(separator: "|")
                }
                CLIOut.out(line)
            }
        }
    }
}

struct StudioRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run a Studio tool on files and save the results.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .customLong("set"), help: "A setting as key=value. Repeat for more.")
    var settings: [String] = []

    @Option(name: .customLong("output-dir"), help: "Save results in this folder.")
    var outputDirectory: String?

    @Argument(help: "The tool id, for example pdf.merge.")
    var tool: String

    @Argument(help: "The files to work on.")
    var files: [String] = []

    func run() async throws {
        try await execute {
            let tool = try StudioBridge.tool(self.tool)
            guard tool.isRunnable else {
                throw CLIFailure.unavailable(
                    "\(tool.title) is an editor", hint: "open it from Studio in the Edith window")
            }
            let inputs = try StudioBridge.files(files)
            let settings = try StudioBridge.settings(self.settings, for: tool)
            let destination: StudioDestination =
                outputDirectory.map {
                    .folder(
                        URL(
                            fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                            isDirectory: true))
                } ?? .nextToOriginal
            let progress = CLIProgress.forCommand(json: json)
            progress.begin(
                "\(tool.title.lowercased()) · \(inputs.count) file\(inputs.count == 1 ? "" : "s")")
            let result: StudioRunResult
            do {
                result = try await StudioRunner.run(
                    tool: tool, inputs: inputs, settings: settings, destination: destination,
                    environment: StudioBridge.environment()
                ) { update in
                    progress.update(
                        "\(tool.title.lowercased()) \(Int((update.fraction * 100).rounded()))%"
                            + (update.status.map { " · \($0)" } ?? ""))
                }
                progress.end()
            } catch let error as StudioError {
                progress.end()
                switch error {
                case let .needsEngine(engine):
                    throw CLIFailure.unavailable(
                        error.localizedDescription,
                        hint: "run `ed tools install \(engine.rawValue)`")
                case .unsupportedInput, .invalidOption, .needsMoreInputs, .needsPassword,
                    .wrongPassword:
                    throw CLIFailure.usage(error.localizedDescription)
                default:
                    throw CLIFailure(error.localizedDescription)
                }
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "tool": .string(tool.id),
                        "outputs": .array(
                            result.outputs.map {
                                .object([
                                    "path": .string($0.url.path), "kind": .string($0.kind.rawValue),
                                    "bytes": .double(Double($0.bytes)),
                                ])
                            }),
                        "inputBytes": .double(Double(result.inputBytes)),
                        "outputBytes": .double(Double(result.outputBytes)),
                        "notes": .array(result.notes.map { .string($0) }),
                        "executed": .bool(true),
                        "failures": .array(
                            result.failures.map {
                                .object(["file": .string($0.file), "message": .string($0.message)])
                            }),
                    ]))
                try StudioBridge.requireNoFailures(result)
                return
            }
            for output in result.outputs {
                CLIOut.out(output.url.path)
            }
            for note in result.notes { CLIOut.note(CLIStyle.dim(note)) }
            for failure in result.failures {
                CLIOut.note(CLIStyle.red("\(failure.file): \(failure.message)"))
            }
            try StudioBridge.requireNoFailures(result)
        }
    }
}

struct StudioProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe", abstract: "Describe a file: kind, size, pages, pixels or duration.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The file to describe.")
    var file: String

    func run() async throws {
        try await execute {
            guard let url = try StudioBridge.files([file]).first else { return }
            let kind = url.studioKind
            var facts: [String: JSONValue] = [
                "path": .string(url.path), "kind": .string(kind.rawValue),
                "bytes": .double(Double(StudioRunner.fileSize(url))),
            ]
            switch kind {
            case .image:
                if let info = StudioImageIO.info(url) {
                    facts["width"] = .double(Double(info.width))
                    facts["height"] = .double(Double(info.height))
                    facts["frames"] = .double(Double(info.frames))
                    facts["alpha"] = .bool(info.hasAlpha)
                }
            case .pdf:
                if let pages = StudioPDF.pageCount(url) { facts["pages"] = .double(Double(pages)) }
            case .video, .audio:
                if let info = await StudioMedia.probe(url, environment: StudioBridge.environment())
                {
                    if let duration = info.duration { facts["duration"] = .double(duration) }
                    if let size = info.displaySize {
                        facts["width"] = .double(Double(size.width))
                        facts["height"] = .double(Double(size.height))
                    }
                    if let codec = info.videoCodec { facts["videoCodec"] = .string(codec) }
                    if let codec = info.audioCodec { facts["audioCodec"] = .string(codec) }
                }
            default:
                break
            }
            facts["tools"] = .array(StudioCatalog.tools(accepting: [url]).map { .string($0.id) })
            guard !json else {
                CLIOut.json(.object(facts))
                return
            }
            for key in facts.keys.sorted() where key != "tools" {
                CLIOut.out("\(key): \(StudioProbeText.value(facts[key]))")
            }
        }
    }
}

enum StudioProbeText {
    static func value(_ value: JSONValue?) -> String {
        switch value {
        case let .string(text): text
        case let .double(number):
            number.rounded() == number ? String(Int(number)) : String(format: "%.3f", number)
        case let .bool(flag): flag ? "yes" : "no"
        default: ""
        }
    }
}
