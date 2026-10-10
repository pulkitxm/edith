import AppKit
import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor struct SkillsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skills",
        abstract: "Read and install bundled skills.",
        discussion: """
            Reads the bundled skill catalog and the agents this Mac already has.
            `ed skills preview` and `ed skills copy` load SKILL.md from GitHub, falling
            back to the last cached copy. `ed skills install` writes that skill into the
            agents you name. Example: `ed skills ls --json`.
            """,
        subcommands: [
            SkillsListCommand.self, SkillsPreviewCommand.self, SkillsCopyCommand.self,
            SkillsInstallCommand.self,
        ],
        defaultSubcommand: SkillsListCommand.self)
}

@MainActor enum SkillsCLI {
    static func skill(_ id: String) throws -> EdithSkill {
        guard let skill = EdithSkillLibrary.skills.first(where: { $0.id == id }) else {
            throw CLIFailure.notFound(
                "no Edith skill named \(id)",
                hint: "run `ed skills ls` to see the library")
        }
        return skill
    }

    static func agents(_ ids: [String]) throws -> [String] {
        let known = Set(SkillAgentCatalog.agents.map(\.id))
        let unique = Array(Set(ids)).sorted()
        let unknown = unique.filter { !known.contains($0) }
        guard unknown.isEmpty, !unique.isEmpty else {
            throw CLIFailure.usage(
                unknown.isEmpty
                    ? "name at least one agent"
                    : "unknown agent: \(unknown.joined(separator: ", "))",
                hint: "run `ed skills ls --json` to see detected agents")
        }
        return unique
    }

    static func targets(named ids: [String]) throws -> [String] {
        if !ids.isEmpty { return try agents(ids) }
        let detected = try SkillsCLIEnvironment.detectAgents().map(\.id)
        let preferences =
            SharedDefaults.store.dictionary(forKey: "plugins.agentSelections")
            as? [String: Bool] ?? [:]
        let selected = detected.filter { preferences[$0] ?? true }
        return try agents(selected)
    }

    static func skillJSON(_ skill: EdithSkill) -> JSONValue {
        .object([
            "detail": .string(skill.detail),
            "id": .string(skill.id),
            "name": .string(skill.name),
            "summary": .string(skill.summary),
        ])
    }

    static func agentJSON(_ agent: SkillAgent, detected: Bool) -> JSONValue {
        .object([
            "detected": .bool(detected),
            "id": .string(agent.id),
            "name": .string(agent.name),
        ])
    }

    static func copyJSON(_ skill: EdithSkill, _ document: SkillDocument, copied: Bool) -> JSONValue
    {
        .object([
            "body": .string(document.body),
            "cached": .bool(document.isCached),
            "copied": .bool(copied),
            "id": .string(skill.id),
            "markdown": .string(document.markdown),
            "name": .string(skill.name),
        ])
    }

    static func documentJSON(_ skill: EdithSkill, _ document: SkillDocument) -> JSONValue {
        .object([
            "body": .string(document.body),
            "cached": .bool(document.isCached),
            "id": .string(skill.id),
            "markdown": .string(document.markdown),
            "name": .string(skill.name),
        ])
    }

    static func load(_ skill: EdithSkill) async throws -> SkillDocument {
        do {
            return try await SkillsCLIEnvironment.documents.load(skill)
        } catch {
            throw CLIFailure(
                error.localizedDescription,
                hint: "check the network, then retry `ed skills preview \(skill.id)`")
        }
    }
}

@MainActor struct SkillsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List Edith skills and the agents that can install them.",
        discussion: """
            Reads the bundled library and which agents are installed on this Mac.
            It does not download skill files or change agent directories.
            Example: `ed skills ls --json`.
            """,
        aliases: ["list"])

    @Flag(name: .long, help: "Emit one JSON document on stdout.")
    var json = false

    @Flag(name: .long, help: "Include every supported agent, not only the ones detected here.")
    var allAgents = false

    func run() async throws {
        try await execute {
            let detected = Set(try SkillsCLIEnvironment.detectAgents().map(\.id))
            let agents =
                allAgents
                ? SkillAgentCatalog.agents
                : SkillAgentCatalog.agents.filter { detected.contains($0.id) }
            if json {
                CLIOut.json(
                    .object([
                        "agents": .array(
                            agents.map {
                                SkillsCLI.agentJSON($0, detected: detected.contains($0.id))
                            }),
                        "skills": .array(EdithSkillLibrary.skills.map(SkillsCLI.skillJSON)),
                    ]))
                return
            }
            for skill in EdithSkillLibrary.skills {
                CLIOut.out("\(skill.id)\t\(skill.name)\t\(skill.summary)")
            }
            if agents.isEmpty {
                CLIOut.note("no agents detected; pass --all-agents to see the catalog")
                return
            }
            CLIOut.out("")
            for agent in agents.sorted(by: { $0.name < $1.name }) {
                let mark = detected.contains(agent.id) ? "detected" : "catalog"
                CLIOut.out("\(agent.id)\t\(agent.name)\t\(mark)")
            }
        }
    }
}

@MainActor struct SkillsPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Print a skill's Markdown body.",
        discussion: """
            Reads SKILL.md from GitHub, or the cached copy when GitHub is unreachable.
            It does not install the skill. Example: `ed skills preview edith-remote-work`.
            """)

    @Flag(name: .long, help: "Emit the document, including the full Markdown, as JSON.")
    var json = false

    @Argument(help: "Skill id from `ed skills ls`.")
    var id: String

    func run() async throws {
        try await execute {
            let skill = try SkillsCLI.skill(id)
            let document = try await SkillsCLI.load(skill)
            if json {
                CLIOut.json(SkillsCLI.documentJSON(skill, document))
            } else {
                CLIOut.out(document.body)
            }
        }
    }
}

@MainActor struct SkillsCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Print a skill's complete Markdown, or copy it to the clipboard.",
        discussion: """
            Reads the same SKILL.md as preview, including its metadata block.
            `--clipboard` replaces the general pasteboard and prints a short confirmation.
            Example: `ed skills copy edith-remote-work --clipboard`.
            """)

    @Flag(name: .long, help: "Emit the document as JSON instead of raw Markdown.")
    var json = false

    @Flag(name: .long, help: "Copy the complete Markdown to the clipboard.")
    var clipboard = false

    @Argument(help: "Skill id from `ed skills ls`.")
    var id: String

    func run() async throws {
        try await execute {
            let skill = try SkillsCLI.skill(id)
            let document = try await SkillsCLI.load(skill)
            if clipboard {
                let board = SkillsCLIEnvironment.clipboard
                board.clearContents()
                guard board.setString(document.markdown, forType: .string) else {
                    throw CLIFailure("could not copy the skill to the clipboard")
                }
            }
            if json {
                CLIOut.json(SkillsCLI.copyJSON(skill, document, copied: clipboard))
            } else if clipboard {
                CLIOut.out("copied \(skill.id)")
            } else {
                CLIOut.raw(document.markdown)
                if !document.markdown.hasSuffix("\n") { CLIOut.raw("\n") }
            }
        }
    }
}

@MainActor struct SkillsInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install one Edith skill into the agents you name.",
        discussion: """
            Previews the skill and agents, then writes the skill with --yes.
            Without --agent it uses the detected agents the install sheet would select.
            Example: `ed skills install edith-remote-work --agent cursor --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the installed agents, as JSON.")
    var json = false

    @Flag(name: .long, help: "Install after printing the plan.")
    var yes = false

    @Option(
        name: .long, parsing: .upToNextOption, help: "Agent id to install into. Repeat to add more."
    )
    var agent: [String] = []

    @Argument(help: "Skill id from `ed skills ls`.")
    var id: String

    func run() async throws {
        try await execute {
            let skill = try SkillsCLI.skill(id)
            let agents = try SkillsCLI.targets(named: agent)
            _ = try SkillInstaller.arguments(skill: skill, agentIDs: agents)
            let plan = CLIDestructivePlan(
                action: "install \(skill.id)", targets: agents, confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let installer = try SkillsCLIEnvironment.installer
            do {
                let emitLogs = !json
                try await installer.install(skill: skill, agentIDs: agents) { line in
                    if emitLogs { CLIOut.note(line) }
                }
            } catch {
                throw CLIFailure(
                    error.localizedDescription,
                    hint: "retry `ed skills install \(skill.id) --yes`")
            }
            plan.finish(
                changed: true,
                plain: "installed \(skill.id) for \(agents.joined(separator: ", "))")
        }
    }
}
