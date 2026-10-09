import EdithExtensionSupport
import EdithStudio
import Foundation

@MainActor
enum StudioCommands {
    nonisolated static let maximumRequestBytes = 512 * 1_024
    nonisolated static let maximumPaths = 500

    enum Failure: LocalizedError, Equatable {
        case invalid(String)
        case unknown(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case let .invalid(message): message
            case let .unknown(command): "Unknown Studio command: \(command)."
            case let .notFound(value): "Studio could not find \(value)."
            }
        }
    }

    private enum Value: Codable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode([Value].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: Value].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .object(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .bool(value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }

    }

    private struct Request: Codable {
        let values: [String: Value]

        init(from decoder: Decoder) throws {
            values = try decoder.singleValueContainer().decode([String: Value].self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(values)
        }

        func optional<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
            guard let value = values[key] else { return nil }
            do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) } catch {
                throw Failure.invalid("Invalid value for \(key).")
            }
        }

        func required<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
            guard let result = try optional(key, as: type) else {
                throw Failure.invalid("Missing required field: \(key).")
            }
            return result
        }

        func flag(_ key: String) throws -> Bool { try optional(key) ?? false }

        func text(_ key: String, maximum: Int = 256) throws -> String {
            let text: String = try required(key)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                text.utf8.count <= maximum
            else { throw Failure.invalid("\(key) must contain 1 to \(maximum) UTF-8 bytes.") }
            return text
        }

        func path(_ key: String) throws -> URL {
            try StudioCommands.localPath(text(key, maximum: 4_096))
        }

        func optionalPath(_ key: String) throws -> URL? {
            guard values[key] != nil else { return nil }
            return try path(key)
        }

        func paths(_ key: String = "paths", allowEmpty: Bool = false) throws -> [URL] {
            let paths: [String] = try required(key)
            guard paths.count <= maximumPaths, allowEmpty || !paths.isEmpty else {
                throw Failure.invalid("\(key) requires 1 to \(maximumPaths) local paths.")
            }
            return try paths.map(StudioCommands.localPath)
        }

        func data(_ key: String) throws -> Data {
            guard let value = values[key] else {
                throw Failure.invalid("Missing required field: \(key).")
            }
            return try JSONEncoder().encode(value)
        }

        func merging<T: Codable>(_ key: String, defaults: T, extraKeys: Set<String> = []) throws
            -> T
        {
            guard let value = values[key] else { return defaults }
            guard case let .object(supplied) = value else {
                throw Failure.invalid("\(key) must be an object.")
            }
            let base = try JSONDecoder().decode(
                [String: Value].self, from: JSONEncoder().encode(defaults))
            guard Set(supplied.keys).isSubset(of: Set(base.keys).union(extraKeys)) else {
                throw Failure.invalid("\(key) contains an unknown field.")
            }
            return try JSONDecoder().decode(
                T.self, from: JSONEncoder().encode(base.merging(supplied) { _, new in new }))
        }
    }

    private struct WorkflowStep: Codable {
        let toolID: String
        let options: [String: String]?
    }

    private struct OptionInfo: Codable {
        let key: String
        let label: String
        let kind: String
        let defaultValue: StudioValue
        let choices: [String]?
        let minimum: Double?
        let maximum: Double?
        let required: Bool
        let help: String?

        init(_ option: StudioOption) {
            key = option.key
            label = option.label
            defaultValue = option.defaultValue
            required = option.isRequired
            help = option.help
            var values: [String]?
            var lower: Double?
            var upper: Double?
            switch option.kind {
            case let .choice(choices): kind = "choice"; values = choices.map(\.value)
            case .toggle: kind = "boolean"
            case let .integer(range, _):
                kind = "integer"; lower = Double(range.lowerBound); upper = Double(range.upperBound)
            case let .number(range, _, _):
                kind = "number"; lower = range.lowerBound; upper = range.upperBound
            case let .percent(range):
                kind = "percent"; lower = range.lowerBound; upper = range.upperBound
            case .text: kind = "text"
            case .longText: kind = "longText"
            case .password: kind = "password"
            case .color: kind = "color"
            case .pages: kind = "pages"
            case .time: kind = "time"
            case .span: kind = "span"
            case .rect: kind = "rect"
            case .file: kind = "file"
            case .font: kind = "font"
            case .anchor: kind = "anchor"
            }
            choices = values
            minimum = lower
            maximum = upper
        }
    }

    private struct ToolInfo: Codable {
        let id: String
        let title: String
        let summary: String
        let family: StudioKind
        let inputs: [StudioKind]
        let runnable: Bool
        let minimumInputs: Int
        let maximumInputs: Int?
        let options: [OptionInfo]
        let requirements: [String]

        init(_ tool: StudioTool) {
            id = tool.id
            title = tool.title
            summary = tool.summary
            family = tool.family
            inputs = tool.inputs.sorted { $0.rawValue < $1.rawValue }
            runnable = tool.isRunnable
            minimumInputs = tool.arity.minimum
            maximumInputs = tool.arity.maximum
            options = tool.options.map(OptionInfo.init)
            requirements = tool.requirements.map(\.title)
        }
    }

    private struct RunResult: Codable {
        let toolID: String
        let outputs: [StudioOutputFile]
        let inputBytes: Int64
        let outputBytes: Int64
        let notes: [String]
        let failures: [StudioFailure]
        let folders: [URL]

        init(_ result: StudioRunResult) {
            toolID = result.toolID
            outputs = result.outputs
            inputBytes = result.inputBytes
            outputBytes = result.outputBytes
            notes = result.notes
            failures = result.failures
            folders = result.folders
        }
    }

    nonisolated static func localPath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4_096,
            !path.utf8.contains(0), !path.contains("://"),
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw Failure.invalid("Expected an absolute local path with at most 4096 UTF-8 bytes.")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func execute(
        _ command: String, payload: Data, model: StudioModel,
        workflowDirectory: URL = DataRoot.studio
    ) async throws -> Data {
        try Task.checkCancellation()
        guard let allowed = fields[command] else { throw Failure.unknown(command) }
        guard !payload.isEmpty, payload.count <= maximumRequestBytes else {
            throw Failure.invalid("Studio command payload must contain 1 to 524288 bytes.")
        }
        try preflight(payload)
        let request: Request
        do { request = try JSONDecoder().decode(Request.self, from: payload) } catch {
            throw Failure.invalid("Studio commands require a JSON object.")
        }
        guard Set(request.values.keys).isSubset(of: allowed) else {
            throw Failure.invalid("Studio command contains an unknown field.")
        }
        if let rate = request.values["frameRate"] {
            guard case let .object(fields) = rate, Set(fields.keys) == ["numerator", "denominator"]
            else {
                throw Failure.invalid("frameRate requires only numerator and denominator.")
            }
        }
        let result = try await dispatch(
            command, request: request, model: model, workflowDirectory: workflowDirectory)
        try Task.checkCancellation()
        guard result.count <= ExtensionPeerEndpoint.maximumPayloadBytes else {
            throw Failure.invalid("Studio command result exceeds the peer payload limit.")
        }
        return result
    }

    private static func preflight(_ data: Data) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }
            } else if byte == 34 {
                inString = true
            } else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 16 else { throw Failure.invalid("JSON nesting exceeds 16 levels.") }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                guard depth >= 0 else {
                    throw Failure.invalid("Studio commands require a JSON object.")
                }
            }
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            throw Failure.invalid("Studio commands require a JSON object.")
        }
        guard object is [String: Any] else {
            throw Failure.invalid("Studio commands require a JSON object.")
        }
        var pending: [(Any, Int)] = [(object, 0)]
        var nodes = 0
        while let (value, depth) = pending.popLast() {
            nodes += 1
            guard nodes <= 16_384 else { throw Failure.invalid("JSON contains too many values.") }
            guard depth <= 16 else { throw Failure.invalid("JSON nesting exceeds 16 levels.") }
            if let values = value as? [String: Any] {
                guard values.count <= 1_000 else {
                    throw Failure.invalid("JSON object is too large.")
                }
                for (key, value) in values {
                    guard !key.isEmpty, key.utf8.count <= 256, !key.utf8.contains(0) else {
                        throw Failure.invalid("JSON contains an invalid field name.")
                    }
                    pending.append((value, depth + 1))
                }
            } else if let values = value as? [Any] {
                guard values.count <= 1_000 else {
                    throw Failure.invalid("JSON array is too large.")
                }
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            } else if let value = value as? String {
                guard value.utf8.count <= 64 * 1_024, !value.utf8.contains(0) else {
                    throw Failure.invalid("JSON contains an invalid or oversized string.")
                }
            } else if let value = value as? NSNumber {
                guard value.doubleValue.isFinite, abs(value.doubleValue) <= 1_000_000_000_000 else {
                    throw Failure.invalid("JSON contains an invalid number.")
                }
            } else {
                throw Failure.invalid("Null command fields are not supported.")
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func tool(_ id: String) throws -> StudioTool {
        guard let tool = StudioCatalog.tool(id) else { throw Failure.notFound(id) }
        return tool
    }

    private static func settings(_ options: [String: String], tool: StudioTool) throws
        -> StudioSettings
    {
        guard options.count <= 64 else {
            throw Failure.invalid("At most 64 tool options are supported.")
        }
        var settings = StudioSettings()
        for (key, raw) in options {
            guard let option = tool.options.first(where: { $0.key == key }),
                raw.utf8.count <= 64 * 1_024
            else {
                throw Failure.invalid("Invalid option: \(key).")
            }
            if case .file = option.kind, !raw.isEmpty { _ = try localPath(raw) }
            let value = try option.parse(raw)
            if case let .number(number) = value, !number.isFinite {
                throw Failure.invalid("Option \(key) must be finite.")
            }
            if case let .span(span) = value,
                !span.start.isFinite || !(span.end?.isFinite ?? true)
            {
                throw Failure.invalid("Option \(key) must use finite times.")
            }
            if case let .rect(rect) = value,
                ![rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite)
            {
                throw Failure.invalid("Option \(key) must use finite rectangle coordinates.")
            }
            settings[key] = value
        }
        return settings
    }

    private static func run(_ tool: StudioTool, request: Request, model: StudioModel) async throws
        -> Data
    {
        let inputs = request.values["paths"] == nil ? [] : try request.paths(allowEmpty: true)
        let options: [String: String] = try request.optional("options") ?? [:]
        let destination = try request.path("output")
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory),
            !directory.boolValue
        {
            throw Failure.invalid("Tool output must be a directory.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            throw Failure.invalid("Tool output directory is not writable.")
        }
        var environment = StudioEngineLocator.detect()
        environment.temporaryRoot = DataRoot.studio.appendingPathComponent(
            "command-staging", isDirectory: true)
        let result = try await StudioRunner.run(
            tool: tool, inputs: inputs, settings: settings(options, tool: tool),
            destination: .folder(destination), environment: environment)
        try Task.checkCancellation()
        model.recordSaved(
            toolID: result.toolID, title: tool.title, outputs: result.outputs.map(\.url))
        return try encode(RunResult(result))
    }

    private static func dispatch(
        _ command: String, request: Request, model: StudioModel, workflowDirectory: URL
    ) async throws -> Data {
        switch command {
        case "studio.tools.list":
            let query: String = try request.optional("query") ?? ""
            let family: StudioKind? = try request.optional("family")
            return try encode(
                StudioCatalog.tools.filter {
                    $0.matches(query) && (family == nil || $0.family == family)
                }.map(ToolInfo.init))
        case "studio.tools.schema": return try encode(ToolInfo(tool(request.text("toolID"))))
        case "studio.tools.run":
            return try await run(tool(request.text("toolID")), request: request, model: model)
        case "studio.library.list":
            return try encode(StudioMediaLibrary.list(defaults: model.defaults))
        case "studio.library.add":
            let urls = try request.paths()
            let expanded = StudioMediaLibrary.expand(urls)
            let current = try StudioMediaLibrary.list(defaults: model.defaults)
            guard Set(current.map(\.url)).union(expanded).count <= 1_000 else {
                throw Failure.invalid(
                    "Studio library supports at most 1000 items through peer commands.")
            }
            let result = try StudioMediaLibrary.add(urls, defaults: model.defaults)
            model.refreshLibrary()
            return try encode(result)
        case "studio.library.remove":
            let result = try StudioMediaLibrary.remove(
                Set(request.paths()), defaults: model.defaults)
            model.refreshLibrary()
            return try encode(result)
        case "studio.library.clear":
            try StudioMediaLibrary.clear(defaults: model.defaults, recent: request.flag("recent"))
            model.refreshLibrary()
            model.loadRecent()
            return try encode([StudioMediaItem]())
        case "studio.workflows.list":
            return try encode(StudioWorkflowFile.load(from: workflowDirectory))
        case "studio.workflows.save":
            let steps: [WorkflowStep] = try request.required("steps")
            guard (1...32).contains(steps.count) else {
                throw Failure.invalid("A workflow requires 1 to 32 steps.")
            }
            guard case let .array(rawSteps)? = request.values["steps"] else {
                throw Failure.invalid("Invalid workflow steps.")
            }
            for step in rawSteps {
                guard case let .object(value) = step,
                    Set(value.keys).isSubset(of: ["toolID", "options"])
                else {
                    throw Failure.invalid("Workflow step contains an unknown field.")
                }
            }
            let identifier: UUID = try request.optional("id") ?? UUID()
            let workflow = try StudioWorkflow(
                id: identifier, name: request.text("name"),
                steps: steps.map { step in
                    let tool = try tool(step.toolID)
                    return StudioWorkflow.Step(
                        toolID: tool.id, settings: try settings(step.options ?? [:], tool: tool))
                })
            try workflow.validate()
            var saved = StudioWorkflowFile.load(from: workflowDirectory)
            if let index = saved.firstIndex(where: { $0.id == identifier }) {
                saved[index] = workflow
            } else {
                guard saved.count < 100 else {
                    throw Failure.invalid("At most 100 saved workflows are supported.")
                }
                saved.append(workflow)
            }
            try StudioWorkflowFile.save(saved, to: workflowDirectory)
            IPC.post(IPC.Name.studioWorkflowsChanged)
            model.loadWorkflows()
            return try encode(workflow)
        case "studio.workflows.remove":
            let identifier: UUID = try request.required("id")
            let saved = StudioWorkflowFile.load(from: workflowDirectory)
            guard saved.contains(where: { $0.id == identifier }) else {
                throw Failure.notFound(identifier.uuidString)
            }
            let remaining = saved.filter { $0.id != identifier }
            try StudioWorkflowFile.save(remaining, to: workflowDirectory)
            IPC.post(IPC.Name.studioWorkflowsChanged)
            model.loadWorkflows()
            return try encode(remaining)
        case "studio.workflows.run":
            let identifier: UUID = try request.required("id")
            guard
                let workflow = StudioWorkflowFile.load(from: workflowDirectory).first(where: {
                    $0.id == identifier
                })
            else {
                throw Failure.notFound(identifier.uuidString)
            }
            try workflow.validate()
            guard let tool = workflow.tool else {
                throw Failure.invalid("Workflow has no runnable steps.")
            }
            return try await run(tool, request: request, model: model)
        default: return try await edit(command, request: request, model: model)
        }
    }

    private static func edit(_ command: String, request: Request, model: StudioModel) async throws
        -> Data
    {
        switch command {
        case "studio.edit.schema":
            return try VideoEditPlan.schema(operation: request.optional("operation"))
        case "studio.edit.audio.health":
            return try encode(
                await StudioAudioMastering.health(environment: StudioEngineLocator.detect()))
        case "studio.edit.create":
            let result = try VideoEditorService.create(
                at: request.path("path"), title: request.text("title"),
                overwrite: request.flag("overwrite"))
            model.refreshProjects()
            return try encode(result)
        case "studio.edit.show": return try VideoEditorService.show(request.path("path"))
        case "studio.edit.apply":
            let plan = try VideoEditPlan.decode(request.data("plan"))
            for operation in plan.operations {
                switch operation {
                case let .addMedia(path, _), let .addStill(path, _, _),
                    let .addAudio(path, _, _, _):
                    _ = try localPath(path)
                default: break
                }
            }
            let result = try await VideoEditorService.apply(
                plan, to: request.path("path"), output: request.optionalPath("output"),
                dryRun: request.flag("dryRun"), overwrite: request.flag("overwrite"),
                expectedRevision: request.optional("expectedRevision"))
            model.refreshProjects()
            return try encode(result)
        case "studio.edit.validate":
            return try encode(await VideoEditorService.validate(request.path("path")))
        case "studio.edit.frame":
            return try encode(
                await VideoEditorService.frame(
                    request.path("path"), at: request.optional("seconds"),
                    frameIndex: request.optional("frame"),
                    to: request.path("output"), overwrite: request.flag("overwrite")))
        case "studio.edit.render":
            let settings = try request.merging(
                "settings", defaults: VideoDeliverySettings(),
                extraKeys: ["colorSpace", "audioCopyTrackID"])
            return try encode(
                await VideoEditorService.render(
                    request.path("path"), to: request.path("output"),
                    overwrite: request.flag("overwrite"),
                    settings: settings, range: deliveryRange(request)))
        case "studio.edit.audio.render":
            return try encode(
                await VideoEditorService.renderAudio(
                    request.path("path"), to: request.path("output"),
                    overwrite: request.flag("overwrite"),
                    settings: request.merging("settings", defaults: VideoAudioDeliverySettings()),
                    range: deliveryRange(request)))
        case "studio.edit.clone":
            let result = try VideoEditorService.clone(
                request.path("path"), to: request.path("output"), title: request.text("title"),
                overwrite: request.flag("overwrite"))
            model.refreshProjects()
            return try encode(result)
        case "studio.edit.list":
            return try encode(VideoEditorService.list(in: request.path("path")))
        case "studio.edit.library": return try encode(VideoEditorService.library())
        case "studio.edit.register":
            let result = try VideoEditorService.register(request.path("path"))
            model.refreshProjects()
            return try encode(result)
        case "studio.edit.unregister":
            let result = try VideoEditorService.unregister(request.path("path"))
            model.refreshProjects()
            return try encode(result)
        case "studio.edit.trash":
            let result = try await VideoEditorService.trashProject(
                request.path("path"), dryRun: request.flag("dryRun"))
            model.refreshProjects()
            return try encode(result)
        default: return try await media(command, request: request)
        }
    }

    private static func deliveryRange(_ request: Request) throws -> VideoDeliveryFrameRange? {
        let start: Int64? = try request.optional("startFrame")
        let end: Int64? = try request.optional("endFrame")
        guard start != nil || end != nil else { return nil }
        guard let start, let end, start >= 0, end > start else {
            throw Failure.invalid("Delivery ranges require 0 <= startFrame < endFrame.")
        }
        return VideoDeliveryFrameRange(startFrame: start, endFrame: end)
    }

    private static func media(_ command: String, request: Request) async throws -> Data {
        switch command {
        case "studio.edit.media.identity":
            return try await VideoEditorService.mediaIdentity(request.path("path"))
        case "studio.edit.media.probe":
            return try await VideoEditorService.mediaProbe(request.path("path"))
        case "studio.edit.media.duplicates":
            return try await VideoEditorService.mediaDuplicates(request.paths())
        case "studio.edit.media.chronology":
            return try await VideoEditorService.mediaChronology(request.paths())
        case "studio.edit.media.index":
            return try await VideoEditorService.mediaIndex(
                request.path("path"), probe: request.flag("probe"),
                output: request.optionalPath("output"),
                dryRun: request.flag("dryRun"), overwrite: request.flag("overwrite"))
        case "studio.edit.media.provenance":
            return try await VideoEditorService.mediaProvenance(
                request.path("path"), assetID: request.text("assetID"),
                familyID: request.text("familyID"),
                declaration: request.text("declaration", maximum: 10_000),
                output: request.optionalPath("output"),
                dryRun: request.flag("dryRun"), overwrite: request.flag("overwrite"))
        case "studio.edit.media.usage":
            return try await VideoEditorService.mediaUsage(
                projects: request.paths(), scope: request.optional("scope") ?? "visual",
                offset: request.optional("offset") ?? 0, limit: request.optional("limit") ?? 100)
        case "studio.edit.media.package":
            return try await VideoEditorService.mediaPackage(
                request.path("path"), to: request.path("output"))
        case "studio.edit.media.open":
            return try await VideoEditorService.mediaOpen(
                request.path("path"), output: request.optionalPath("output"),
                dryRun: request.flag("dryRun"), overwrite: request.flag("overwrite"))
        case "studio.edit.media.relink":
            return try await VideoEditorService.mediaRelink(
                request.path("path"), referenceID: request.text("referenceID"),
                role: request.optional("role") ?? "original",
                to: request.path("media"), policy: request.optional("policy") ?? "requireIdentity",
                expectedSHA256: request.optional("expectedSHA256"),
                expectedByteCount: request.optional("expectedByteCount"),
                output: request.optionalPath("output"), dryRun: request.flag("dryRun"),
                overwrite: request.flag("overwrite"))
        case "studio.edit.media.reserve":
            return try await VideoEditorService.mediaReserve(
                request.path("path"), ledger: request.path("ledger"), reelID: request.text("reelID")
            )
        case "studio.edit.media.reservations":
            return try await VideoEditorService.mediaReservations(
                request.path("ledger"), offset: request.optional("offset") ?? 0,
                limit: request.optional("limit") ?? 100)
        case "studio.edit.media.release":
            return try await VideoEditorService.mediaRelease(
                request.path("ledger"), receiptFile: request.path("receiptFile"))
        default: return try await annotations(command, request: request)
        }
    }

    private static func annotations(_ command: String, request: Request) async throws -> Data {
        let url = try request.path("path")
        switch command {
        case "studio.edit.captions.list": return try encode(VideoEditorService.listCaptions(url))
        case "studio.edit.captions.add":
            return try encode(
                await VideoEditorService.changeCaption(
                    .add(
                        content: request.text("content", maximum: 10_000),
                        start: captionBoundary(request, prefix: "start")!,
                        end: captionBoundary(request, prefix: "end")!, rate: captionRate(request),
                        style: captionStyle(request)),
                    in: url, dryRun: request.flag("dryRun")))
        case "studio.edit.captions.update":
            let hasBoundary =
                request.values["startFrame"] != nil || request.values["endFrame"] != nil
                || request.values["startMarker"] != nil || request.values["endMarker"] != nil
            return try encode(
                await VideoEditorService.changeCaption(
                    .update(
                        id: request.text("id"), content: request.optional("content"),
                        start: captionBoundary(request, prefix: "start", required: false),
                        end: captionBoundary(request, prefix: "end", required: false),
                        rate: hasBoundary ? captionRate(request) : nil, style: captionStyle(request)
                    ),
                    in: url, dryRun: request.flag("dryRun")))
        case "studio.edit.captions.remove":
            return try encode(
                await VideoEditorService.changeCaption(
                    .remove(id: request.text("id")), in: url, dryRun: request.flag("dryRun")))
        case "studio.edit.markers.list": return try encode(VideoEditorService.listMarkers(url))
        case "studio.edit.markers.add":
            return try encode(
                await VideoEditorService.changeMarkers(
                    .add(
                        frame: request.required("frame"), rate: markerRate(request),
                        label: request.optional("label") ?? ""),
                    in: url, dryRun: request.flag("dryRun")))
        case "studio.edit.markers.update":
            let frame: Int64? = try request.optional("frame")
            return try encode(
                await VideoEditorService.changeMarkers(
                    .update(
                        id: request.text("id"), frame: frame,
                        rate: frame == nil ? nil : markerRate(request),
                        label: request.optional("label")),
                    in: url, dryRun: request.flag("dryRun")))
        case "studio.edit.markers.remove":
            return try encode(
                await VideoEditorService.changeMarkers(
                    .remove(id: request.text("id")), in: url, dryRun: request.flag("dryRun")))
        case "studio.edit.markers.import":
            return try encode(
                await VideoEditorService.changeMarkers(
                    .importDocument(request.data("document"), replace: request.flag("replace")),
                    in: url, dryRun: request.flag("dryRun")))
        case "studio.edit.markers.export":
            return try encode(
                VideoEditorService.exportMarkers(
                    url, to: request.path("output"), overwrite: request.flag("overwrite")))
        case "studio.edit.markers.snap":
            return try encode(
                await VideoEditorService.snapMarker(
                    url, frame: request.required("frame"),
                    thresholdFrames: request.required("thresholdFrames"), rate: markerRate(request))
            )
        case "studio.edit.review.report":
            var options = VideoEditorService.ReviewOptions()
            options.expectedDuration = try request.optional("expectedDuration")
            options.expectedFrameCount = try request.optional("expectedFrameCount")
            options.expectedShotCount = try request.optional("expectedShotCount")
            options.checkBorders = try request.flag("checkBorders")
            options.maximumBorderFrames = try request.optional("maximumBorderFrames") ?? 10_000
            options.durationTolerance = try request.optional("durationTolerance") ?? 0.001
            let report = try await VideoEditorService.reviewReport(url, options: options)
            if let output = try request.optionalPath("output") {
                return try encode(
                    VideoEditorService.writeReviewReport(
                        report, project: url, to: output, overwrite: request.flag("overwrite")))
            }
            return try encode(report)
        case "studio.edit.review.contactSheet":
            return try encode(
                await VideoEditorService.contactSheet(
                    url, times: request.required("times"),
                    columns: request.optional("columns") ?? 4,
                    cellWidth: request.optional("cellWidth") ?? 320, to: request.path("output"),
                    overwrite: request.flag("overwrite")))
        case "studio.edit.audio.measure":
            return try encode(
                await VideoEditorService.measureAudio(url, assetID: request.text("assetID")))
        case "studio.edit.audio.master":
            return try encode(
                await VideoEditorService.masterAudio(
                    url, trackID: request.text("trackID"), to: request.path("output"),
                    request: StudioAudioMastering.Request(
                        durationSeconds: request.required("durationSeconds"))))
        default: throw Failure.unknown(command)
        }
    }

    private static func captionBoundary(_ request: Request, prefix: String, required: Bool = true)
        throws -> VideoEditorService.CaptionBoundary?
    {
        let frame: Int64? = try request.optional(prefix + "Frame")
        let marker: String? = try request.optional(prefix + "Marker")
        guard frame == nil || marker == nil else {
            throw Failure.invalid("Choose either \(prefix)Frame or \(prefix)Marker.")
        }
        if let frame { return .frame(frame) }
        if let marker { return .marker(marker) }
        guard !required else { throw Failure.invalid("Missing caption \(prefix) boundary.") }
        return nil
    }

    private static func captionRate(_ request: Request) throws -> VideoEditorService.CaptionRate {
        guard let rate: VideoMarkerFrameRate = try request.optional("frameRate") else {
            return .project
        }
        return .explicit(
            try VideoCaptionFrameRate(numerator: rate.numerator, denominator: rate.denominator))
    }

    private static func markerRate(_ request: Request) throws -> VideoEditorService.MarkerRate {
        guard let rate: VideoMarkerFrameRate = try request.optional("frameRate") else {
            return .project
        }
        return .explicit(rate)
    }

    private static func captionStyle(_ request: Request) throws -> VideoCaptionStyle? {
        guard request.values["style"] != nil else { return nil }
        return try VideoCaptionStyle.decode(request.data("style"))
    }

    static var commandNames: [String] { fields.keys.sorted() }

    private static let fields: [String: Set<String>] = [
        "studio.tools.list": ["query", "family"],
        "studio.tools.schema": ["toolID"],
        "studio.tools.run": ["toolID", "paths", "options", "output"],
        "studio.library.list": [],
        "studio.library.add": ["paths"],
        "studio.library.remove": ["paths"],
        "studio.library.clear": ["recent"],
        "studio.workflows.list": [],
        "studio.workflows.save": ["id", "name", "steps"],
        "studio.workflows.remove": ["id"],
        "studio.workflows.run": ["id", "paths", "output"],
        "studio.edit.schema": ["operation"],
        "studio.edit.create": ["path", "title", "overwrite"],
        "studio.edit.show": ["path"],
        "studio.edit.apply": ["path", "plan", "output", "dryRun", "overwrite", "expectedRevision"],
        "studio.edit.validate": ["path"],
        "studio.edit.frame": ["path", "seconds", "frame", "output", "overwrite"],
        "studio.edit.render": [
            "path", "output", "overwrite", "settings", "startFrame", "endFrame",
        ],
        "studio.edit.audio.render": [
            "path", "output", "overwrite", "settings", "startFrame", "endFrame",
        ],
        "studio.edit.audio.measure": ["path", "assetID"],
        "studio.edit.audio.master": ["path", "trackID", "output", "durationSeconds"],
        "studio.edit.audio.health": [],
        "studio.edit.clone": ["path", "output", "title", "overwrite"],
        "studio.edit.list": ["path"],
        "studio.edit.library": [],
        "studio.edit.register": ["path"],
        "studio.edit.unregister": ["path"],
        "studio.edit.trash": ["path", "dryRun"],
        "studio.edit.media.identity": ["path"],
        "studio.edit.media.probe": ["path"],
        "studio.edit.media.duplicates": ["paths"],
        "studio.edit.media.chronology": ["paths"],
        "studio.edit.media.index": ["path", "probe", "output", "dryRun", "overwrite"],
        "studio.edit.media.provenance": [
            "path", "assetID", "familyID", "declaration", "output", "dryRun", "overwrite",
        ],
        "studio.edit.media.usage": ["paths", "scope", "offset", "limit"],
        "studio.edit.media.package": ["path", "output"],
        "studio.edit.media.open": ["path", "output", "dryRun", "overwrite"],
        "studio.edit.media.relink": [
            "path", "referenceID", "role", "media", "policy", "expectedSHA256", "expectedByteCount",
            "output", "dryRun", "overwrite",
        ],
        "studio.edit.media.reserve": ["path", "ledger", "reelID"],
        "studio.edit.media.reservations": ["ledger", "offset", "limit"],
        "studio.edit.media.release": ["ledger", "receiptFile"],
        "studio.edit.captions.list": ["path"],
        "studio.edit.captions.add": [
            "path", "content", "startFrame", "endFrame", "startMarker", "endMarker", "frameRate",
            "style", "dryRun",
        ],
        "studio.edit.captions.update": [
            "path", "id", "content", "startFrame", "endFrame", "startMarker", "endMarker",
            "frameRate", "style", "dryRun",
        ],
        "studio.edit.captions.remove": ["path", "id", "dryRun"],
        "studio.edit.markers.list": ["path"],
        "studio.edit.markers.add": ["path", "frame", "frameRate", "label", "dryRun"],
        "studio.edit.markers.update": ["path", "id", "frame", "frameRate", "label", "dryRun"],
        "studio.edit.markers.remove": ["path", "id", "dryRun"],
        "studio.edit.markers.import": ["path", "document", "replace", "dryRun"],
        "studio.edit.markers.export": ["path", "output", "overwrite"],
        "studio.edit.markers.snap": ["path", "frame", "thresholdFrames", "frameRate"],
        "studio.edit.review.report": [
            "path", "output", "overwrite", "expectedDuration", "expectedFrameCount",
            "expectedShotCount", "checkBorders", "maximumBorderFrames", "durationTolerance",
        ],
        "studio.edit.review.contactSheet": [
            "path", "times", "columns", "cellWidth", "output", "overwrite",
        ],
    ]
}
