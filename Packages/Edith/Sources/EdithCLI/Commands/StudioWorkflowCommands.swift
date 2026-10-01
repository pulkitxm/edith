import ArgumentParser
import EdithKit
import EdithStudio
import Foundation

struct StudioWorkflowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow",
        abstract: "List, save, run and delete Studio workflows.",
        discussion: """
            Reads the saved workflow cards and writes one when you save or delete it.
            Example: `ed studio workflow ls --json`.
            """,
        subcommands: [
            StudioWorkflowListCommand.self, StudioWorkflowSaveCommand.self,
            StudioWorkflowRunCommand.self, StudioWorkflowRemoveCommand.self,
        ],
        defaultSubcommand: StudioWorkflowListCommand.self)
}

enum StudioWorkflowCLI {
    static var directory: URL { DataRoot.studio }

    static func load() -> [StudioWorkflow] { StudioWorkflowFile.load(from: directory) }

    static func store(_ workflows: [StudioWorkflow]) throws {
        try StudioWorkflowFile.save(workflows, to: directory)
        AppBridge.post(IPC.Name.studioWorkflowsChanged)
    }

    static func find(_ name: String, in workflows: [StudioWorkflow]) throws -> StudioWorkflow {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIFailure.usage("name the workflow")
        }
        if let id = UUID(uuidString: trimmed), let match = workflows.first(where: { $0.id == id }) {
            return match
        }
        let matches = workflows.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if matches.count == 1, let match = matches.first { return match }
        if matches.count > 1 {
            throw CLIFailure(
                "\(trimmed) matches more than one workflow", hint: "pass the workflow id")
        }
        throw CLIFailure.notFound(
            "no workflow called \(trimmed)", hint: "run `ed studio workflow ls`")
    }

    static func steps(_ ids: [String], settings: [String]) throws -> [StudioWorkflow.Step] {
        guard !ids.isEmpty else {
            throw CLIFailure.usage("add at least one --step", hint: "for example --step pdf.ocr")
        }
        var built: [StudioWorkflow.Step] = []
        for id in ids {
            let tool = try StudioBridge.tool(id)
            guard StudioWorkflow.canChain(tool) else {
                throw CLIFailure.usage("\(tool.title) cannot be part of a workflow")
            }
            built.append(StudioWorkflow.Step(toolID: tool.id))
        }
        for pair in settings {
            guard let colon = pair.firstIndex(of: ":") else {
                throw CLIFailure.usage("--set needs toolID:key=value, got \(pair)")
            }
            let toolID = String(pair[..<colon])
            let assignment = String(pair[pair.index(after: colon)...])
            guard let index = built.firstIndex(where: { $0.toolID == toolID }) else {
                throw CLIFailure.usage("no step uses \(toolID)")
            }
            guard let tool = built[index].tool else {
                throw CLIFailure.usage("\(toolID) is not a Studio tool")
            }
            let parsed = try StudioBridge.settings([assignment], for: tool)
            var current = built[index].settings
            for (key, value) in parsed.values { current[key] = value }
            built[index].settings = current
        }
        return built
    }

    static func emit(_ workflows: [StudioWorkflow], json: Bool) {
        if json {
            CLIOut.json(
                .object([
                    "workflows": .array(workflows.map(jsonWorkflow))
                ]))
            return
        }
        if workflows.isEmpty {
            CLIOut.out("No workflows saved.")
            return
        }
        for workflow in workflows {
            CLIOut.out("\(workflow.name)\t\(workflow.summary)")
        }
    }

    static func jsonWorkflow(_ workflow: StudioWorkflow) -> JSONValue {
        .object([
            "id": .string(workflow.id.uuidString.lowercased()),
            "name": .string(workflow.name),
            "steps": .array(workflow.steps.map { .object(["tool": .string($0.toolID)]) }),
            "summary": .string(workflow.summary),
        ])
    }
}

struct StudioWorkflowListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List saved Studio workflows.",
        discussion: """
            Reads the workflow cards, including the built-in presets until you save your own.
            Example: `ed studio workflow ls --json`.
            """)

    @Flag(name: .long, help: "Emit the workflows as JSON.")
    var json = false

    func run() async throws {
        try await execute { StudioWorkflowCLI.emit(StudioWorkflowCLI.load(), json: json) }
    }
}

struct StudioWorkflowSaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Save a chain of Studio tools as a workflow.",
        discussion: """
            Writes the chain, replacing a workflow with the same name or adding one.
            Repeat --step in order. Settings use toolID:key=value.
            Example: `ed studio workflow save "Web photos" --step image.compress --json`.
            """)

    @Argument(help: "The workflow name.")
    var name: String

    @Option(name: .customLong("step"), help: "A tool id. Repeat in the order the workflow runs.")
    var steps: [String] = []

    @Option(
        name: .customLong("set"),
        help: "A setting for one step, as toolID:key=value. Repeat for more.")
    var settings: [String] = []

    @Flag(name: .long, help: "Emit the saved workflow as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            let steps = try StudioWorkflowCLI.steps(self.steps, settings: settings)
            var workflows = StudioWorkflowCLI.load()
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = workflows.first {
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }
            let workflow = StudioWorkflow(id: existing?.id ?? UUID(), name: trimmed, steps: steps)
            try workflow.validate()
            if let index = workflows.firstIndex(where: { $0.id == workflow.id }) {
                workflows[index] = workflow
            } else {
                workflows.append(workflow)
            }
            try StudioWorkflowCLI.store(workflows)
            StudioWorkflowCLI.emit([workflow], json: json)
        }
    }
}

struct StudioWorkflowRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a saved workflow on files.",
        discussion: """
            Writes each tool's result, the same chain as the workflow card's Run button.
            Results land next to the originals unless you pass --output-dir.
            Example: `ed studio workflow run "Web photos" photo.png --json`.
            """)

    @Flag(name: .long, help: "Emit the outputs as JSON.")
    var json = false

    @Option(name: .customLong("output-dir"), help: "Save results in this folder.")
    var outputDirectory: String?

    @Argument(help: "The workflow name or id.")
    var name: String

    @Argument(help: "The files to run the workflow on.")
    var files: [String] = []

    func run() async throws {
        try await execute {
            let workflow = try StudioWorkflowCLI.find(name, in: StudioWorkflowCLI.load())
            guard let tool = workflow.tool else {
                throw CLIFailure("\(workflow.name) has no tools")
            }
            let inputs = try StudioBridge.files(files)
            let destination: StudioDestination =
                outputDirectory.map {
                    .folder(
                        URL(
                            fileURLWithPath: ($0 as NSString).expandingTildeInPath,
                            isDirectory: true))
                } ?? .nextToOriginal
            let result: StudioRunResult
            do {
                result = try await StudioRunner.run(
                    tool: tool, inputs: inputs, settings: StudioSettings(),
                    destination: destination, environment: StudioBridge.environment()
                ) { _ in }
            } catch let error as StudioError {
                throw CLIFailure(error.localizedDescription)
            }
            if json {
                CLIOut.json(
                    .object([
                        "executed": .bool(true),
                        "failures": .array(
                            result.failures.map {
                                .object(["file": .string($0.file), "message": .string($0.message)])
                            }),
                        "outputs": .array(result.outputs.map { .string($0.url.path) }),
                        "workflow": .string(workflow.name),
                    ]))
            } else {
                for output in result.outputs { CLIOut.out(output.url.path) }
            }
            try StudioBridge.requireNoFailures(result)
        }
    }
}

struct StudioWorkflowRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete a saved Studio workflow.",
        discussion: """
            Previews the deletion, then --yes writes the removal of the workflow card.
            Example: `ed studio workflow rm "Web photos" --yes`.
            """)

    @Argument(help: "The workflow name or id.")
    var name: String

    @Flag(name: .long, help: "Delete after printing the plan.")
    var yes = false

    @Flag(name: .long, help: "Emit the plan, or the remaining workflows, as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            var workflows = StudioWorkflowCLI.load()
            let workflow = try StudioWorkflowCLI.find(name, in: workflows)
            let plan = CLIDestructivePlan(
                action: "delete workflow \(workflow.name)", targets: [workflow.name],
                confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            workflows.removeAll { $0.id == workflow.id }
            try StudioWorkflowCLI.store(workflows)
            if json {
                CLIOut.json(
                    .object([
                        "deleted": .string(workflow.name),
                        "workflows": .array(workflows.map(StudioWorkflowCLI.jsonWorkflow)),
                    ]))
            } else {
                plan.finish(changed: true, plain: "Deleted \(workflow.name)")
            }
        }
    }
}
