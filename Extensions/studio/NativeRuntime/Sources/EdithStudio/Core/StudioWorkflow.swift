import Foundation

public struct StudioWorkflow: Codable, Hashable, Identifiable, Sendable {
    public struct Step: Codable, Hashable, Sendable {
        public var toolID: String
        public var settings: StudioSettings

        public init(toolID: String, settings: StudioSettings = StudioSettings()) {
            self.toolID = toolID
            self.settings = settings
        }

        public var tool: StudioTool? { StudioCatalog.tool(toolID) }
    }

    public var id: UUID
    public var name: String
    public var steps: [Step]

    public init(id: UUID = UUID(), name: String, steps: [Step]) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    public var toolID: String { "workflow.\(id.uuidString.lowercased())" }

    public var tools: [StudioTool] { steps.compactMap(\.tool) }

    public var summary: String {
        tools.map(\.title).joined(separator: " → ")
    }

    public static func canChain(_ tool: StudioTool) -> Bool {
        tool.isRunnable && tool.style == .run && tool.arity != .none && tool.produces != .report
    }

    public static func products(of tool: StudioTool, from kinds: Set<StudioKind>) -> Set<StudioKind>
    {
        switch tool.produces {
        case .same: kinds
        case let .kind(kind): [kind]
        case .report: []
        }
    }

    public func kinds(after index: Int, starting: Set<StudioKind>) -> Set<StudioKind> {
        var kinds = starting
        for step in steps.prefix(index + 1) {
            guard let tool = step.tool else { return [] }
            kinds = Self.products(of: tool, from: kinds.filter { tool.accepts(kind: $0) })
        }
        return kinds
    }

    public func candidates(after index: Int) -> [StudioTool] {
        guard index >= 0, let first = steps.first?.tool else {
            return StudioCatalog.tools.filter(Self.canChain)
        }
        let produced = kinds(after: index, starting: first.inputs)
        return StudioCatalog.tools.filter { tool in
            Self.canChain(tool) && !produced.isDisjoint(with: tool.inputs)
        }
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StudioError.invalidOption("name", "give the workflow a name")
        }
        guard let first = steps.first?.tool else {
            throw StudioError.invalidOption("steps", "add at least one tool")
        }
        var kinds = first.inputs
        for (index, step) in steps.enumerated() {
            guard let tool = step.tool, Self.canChain(tool) else {
                throw StudioError.invalidOption(
                    "steps", "step \(index + 1) cannot be part of a workflow")
            }
            let usable = kinds.filter { tool.accepts(kind: $0) }
            guard !usable.isEmpty else {
                throw StudioError.invalidOption(
                    "steps", "\(tool.title) cannot use what step \(index) produces")
            }
            let merged = step.settings.merged(over: tool.defaultSettings)
            for option in tool.options where option.isRequired && option.isVisible(in: merged) {
                if merged.trimmed(option.key).isEmpty {
                    throw StudioError.invalidOption(
                        option.label.lowercased(), "step \(index + 1), \(tool.title), needs it")
                }
            }
            kinds = Self.products(of: tool, from: usable)
        }
    }

    public var tool: StudioTool? {
        guard let first = steps.first?.tool else { return nil }
        let workflow = self
        let title = name
        return StudioTool(
            id: toolID, title: title,
            summary: summary.isEmpty ? "Runs a saved chain of tools." : summary,
            symbol: "arrow.triangle.branch", group: .create, inputs: first.inputs,
            extraExtensions: first.extraExtensions, arity: .combine(minimum: 1, maximum: nil),
            produces: .same, keywords: ["workflow", "automation"], actionTitle: "Run workflow",
            family: first.family
        ) { run in
            try await workflow.perform(run)
        }
    }

    func perform(_ run: StudioRun) async throws -> [URL] {
        try validate()
        var current = run.inputs
        let count = Double(steps.count)
        for (index, step) in steps.enumerated() {
            try run.checkCancellation()
            guard let tool = step.tool else {
                throw StudioError.failed("A workflow tool is missing.")
            }
            run.status("Step \(index + 1) of \(steps.count): \(tool.title)")
            let usable = current.filter(tool.accepts)
            guard !usable.isEmpty else {
                throw StudioError.nothingToDo(
                    "\(tool.title) has nothing to work on after step \(index).")
            }
            let folder = try run.scratch("step-\(index + 1)")
            let result = try await StudioRunner.run(
                tool: tool, inputs: usable, settings: step.settings, destination: .folder(folder),
                environment: run.environment
            ) { progress in
                run.progress((Double(index) + progress.fraction) / count)
            }
            for note in result.notes { run.note("\(tool.title): \(note)") }
            for failure in result.failures {
                run.note("\(tool.title) skipped \(failure.file): \(failure.message)")
            }
            current = result.outputs.map(\.url)
        }
        var outputs: [URL] = []
        for file in current {
            let target = run.output(named: file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: target)
            outputs.append(target)
        }
        return outputs
    }

    public static let presets: [StudioWorkflow] = [
        StudioWorkflow(
            name: "Searchable, smaller scans",
            steps: [Step(toolID: "pdf.ocr"), Step(toolID: "pdf.compress")]),
        StudioWorkflow(
            name: "Photos ready for the web",
            steps: [
                Step(
                    toolID: "image.resize",
                    settings: StudioSettings(["mode": .text("longest"), "longest": .number(2048)])),
                Step(toolID: "image.metadata"),
                Step(toolID: "image.compress"),
            ]),
        StudioWorkflow(
            name: "Merge, number and compress",
            steps: [
                Step(toolID: "pdf.merge"), Step(toolID: "pdf.page-numbers"),
                Step(toolID: "pdf.compress"),
            ]),
    ]
}
