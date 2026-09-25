import ArgumentParser
import EdithDocs
import EdithKit
import Foundation

struct DocsCommandGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docs",
        abstract: "Read the ed reference and ask which command handles a request.",
        subcommands: [DocsListCommand.self, DocsShowCommand.self, DocsAskCommand.self],
        defaultSubcommand: DocsListCommand.self)
}

enum DocsCLI {
    static func library() throws -> DocsLibrary {
        guard let library = DocsLibrary.bundled() else {
            throw CLIFailure.unavailable(
                "the bundled documentation is missing", hint: "reinstall Edith")
        }
        return library
    }

    static func anchor(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }
}

struct DocsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the documentation pages, optionally for one group.",
        aliases: ["list"])

    @Option(help: "Only pages in this group, such as herdr or machines-docker.")
    var group: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let library = try DocsCLI.library()
            let pages = library.pages(inGroup: group)
            guard !pages.isEmpty else {
                throw CLIFailure.notFound(
                    "no documentation group named \(group ?? "")",
                    hint: "run `ed docs ls` for every page")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "pages": .array(
                            pages.map { page in
                                .object([
                                    "path": .string(page.path), "title": .string(page.title),
                                    "group": .string(page.group),
                                    "command": page.command.map(JSONValue.string) ?? .null,
                                ])
                            })
                    ]))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["PATH", "TITLE"], rows: pages.map { [$0.path, $0.title] }))
        }
    }
}

struct DocsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print one page, found by its path or by a command it documents.")

    @Argument(help: "A page path such as herdr/ls.md, or a command such as herdr ls.")
    var target: [String] = []

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let query = target.joined(separator: " ")
            guard !query.isEmpty else {
                throw CLIFailure.usage("name a page or a command", hint: "ed docs show herdr ls")
            }
            let library = try DocsCLI.library()
            guard let location = library.lookup(query), let page = library.page(location.path)
            else {
                throw CLIFailure.notFound(
                    "no page documents \(query)", hint: "ed docs ask \"\(query)\"")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "path": .string(page.path), "title": .string(page.title),
                        "anchor": DocsCLI.anchor(location.anchor),
                        "anchors": .array(
                            page.headings.map { heading in
                                .object([
                                    "level": .int(heading.level), "title": .string(heading.text),
                                    "anchor": .string(heading.anchor),
                                ])
                            }),
                        "markdown": .string(page.markdown),
                    ]))
                return
            }
            CLIOut.raw(page.markdown)
        }
    }
}

struct DocsAskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Rank the commands that handle a plain-language request.",
        discussion:
            "Uses Jev when a TypeSafe key is saved and the local search index otherwise.")

    @Argument(help: "What you want to do, such as \"free up docker space on my server\".")
    var request: [String] = []

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let text = request.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                throw CLIFailure.usage(
                    "say what you want to do", hint: "ed docs ask \"restart the background agent\"")
            }
            let answer = await DocsAsk.answer(
                text, in: try DocsCLI.library(), decider: AgentJevDecider.configured())
            guard !json else {
                CLIOut.json(
                    .object([
                        "request": .string(answer.request),
                        "engine": .string(answer.engine.rawValue),
                        "latencyMs": .int(answer.milliseconds),
                        "picks": .array(
                            answer.picks.map { pick in
                                .object([
                                    "command": .string(pick.command.path),
                                    "summary": .string(pick.command.summary),
                                    "page": .string(pick.command.location.path),
                                    "anchor": DocsCLI.anchor(pick.command.location.anchor),
                                    "probability": .double(pick.probability),
                                ])
                            }),
                    ]))
                return
            }
            guard !answer.picks.isEmpty else {
                CLIOut.note("nothing in the reference matches that request")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["COMMAND", "CONFIDENCE", "PAGE"],
                    rows: answer.picks.map { pick in
                        let page = pick.command.location.path
                        return [
                            pick.command.path, "\(Int((pick.probability * 100).rounded()))%",
                            pick.command.location.anchor.map { "\(page)#\($0)" } ?? page,
                        ]
                    }))
            CLIOut.note("answered by \(answer.engine.label)")
        }
    }
}
