import ArgumentParser
import CryptoKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

enum LaTeXCLIEnvironment {
    nonisolated(unsafe) static var store = LaTeXProjectStore()
    nonisolated(unsafe) static var service = LaTeXService.live
    nonisolated(unsafe) static var input: @Sendable () throws -> Data = {
        Data()
    }

    static func reset() {
        store = LaTeXProjectStore()
        service = .live
        input = { Data() }
    }
}

@MainActor struct LaTeXCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "latex",
        abstract: "Edit LaTeX projects, compile PDFs, and review repository changes.",
        discussion: """
            Reads the same project library as the editor. Disk projects save and compile locally.
            Repository edits create or update a pull request through Pukbot and compile on GitHub.
            Source reads and PDF previews stay in memory for repositories. Example: ed latex ls --json
            """,
        subcommands: [
            LaTeXListCommand.self, LaTeXAddCommand.self, LaTeXReadCommand.self,
            LaTeXWriteCommand.self, LaTeXEditCommand.self, LaTeXCompileCommand.self,
            LaTeXReviewCommand.self, LaTeXPreviewCommand.self, LaTeXMergeCommand.self,
            LaTeXRemoveCommand.self,
        ], defaultSubcommand: LaTeXListCommand.self)
}

@MainActor struct LaTeXTargetOptions: ParsableArguments {
    @Argument(help: "Project UUID from ed latex ls.") var project: String
    @Flag(name: .long, help: "Emit one JSON document on stdout.") var json = false
}

@MainActor struct LaTeXSaveOptions: ParsableArguments {
    @OptionGroup var target: LaTeXTargetOptions
    @Option(
        name: .long, help: "Revision returned by ed latex read, required to prevent overwrites.")
    var revision: String
    @Flag(
        name: .long,
        help: "Apply the source change and compile, otherwise print the proposed source.")
    var yes = false
}

struct LaTeXTextEdit: Decodable {
    let find: String
    let replace: String
    let expectedMatches: Int

    static func apply(_ edits: [Self], to source: String) throws -> String {
        guard !edits.isEmpty else { throw CLIFailure.usage("provide at least one edit") }
        return try edits.reduce(source) { text, edit in
            guard !edit.find.isEmpty, edit.expectedMatches > 0 else {
                throw CLIFailure.usage(
                    "each edit needs nonempty find text and positive expectedMatches")
            }
            let matches = text.components(separatedBy: edit.find).count - 1
            guard matches == edit.expectedMatches else {
                throw CLIFailure(
                    "expected \(edit.expectedMatches) matches, found \(matches); source was not changed"
                )
            }
            return text.replacingOccurrences(of: edit.find, with: edit.replace)
        }
    }
}

@MainActor enum LaTeXCLI {
    static func project(_ id: String) throws -> LaTeXProject {
        guard let uuid = UUID(uuidString: id),
            let project = try LaTeXCLIEnvironment.store.load().first(where: { $0.id == uuid })
        else {
            throw CLIFailure.notFound(
                "no LaTeX project with id \(id)", hint: "run ed latex ls --json")
        }
        return project
    }

    static func persist(_ project: LaTeXProject) throws {
        var projects = try LaTeXCLIEnvironment.store.load()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        try LaTeXCLIEnvironment.store.save(projects)
    }

    static func json(_ project: LaTeXProject) -> JSONValue {
        .object([
            "id": .string(project.id.uuidString), "name": .string(project.name),
            "location": .string(project.location.rawValue),
            "compiler": .string(project.compiler.rawValue),
            "sourcePath": .string(project.sourcePath), "repository": .string(project.repository),
            "baseBranch": .string(project.baseBranch),
            "reviewBranch": project.reviewBranch.map(JSONValue.string) ?? .null,
            "pullRequest": project.pullRequest.map(JSONValue.int) ?? .null,
        ])
    }

    static func revision(_ source: LaTeXSource) -> String {
        SHA256.hash(data: Data(source.revision.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func input() throws -> String {
        let bytes = try LaTeXCLIEnvironment.input()
        guard bytes.count <= 1_048_576, let text = String(data: bytes, encoding: .utf8) else {
            throw CLIFailure.usage("stdin must contain UTF-8 text of at most 1 MiB")
        }
        return text
    }

    static func source(_ project: LaTeXProject) async throws -> LaTeXSource {
        try await LaTeXCLIEnvironment.service.load(project)
    }

    static func current(_ id: String) async throws -> LaTeXProject {
        var project = try project(id)
        if project.location == .github, project.pullRequest != nil {
            let review = try await LaTeXCLIEnvironment.service.review(project)
            if review.pullRequest.state != "OPEN" {
                project.reviewBranch = nil
                project.pullRequest = nil
            }
        }
        return project
    }

    static func checkedSource(_ project: LaTeXProject, revision: String) async throws -> LaTeXSource
    {
        let source = try await source(project)
        guard Self.revision(source) == revision else {
            throw CLIFailure("source revision changed; read it again before editing")
        }
        return source
    }

    static func save(
        _ project: LaTeXProject, source: LaTeXSource, text: String, options: LaTeXSaveOptions
    ) async throws {
        let plan = CLIDestructivePlan(
            action: project.location == .disk
                ? "save and compile LaTeX" : "submit LaTeX pull request",
            targets: [project.name], confirmed: options.yes, json: options.target.json,
            fields: [
                "project": json(project), "source": .string(text),
                "revision": .string(revision(source)),
            ])
        guard plan.shouldApply() else { return }
        let service = LaTeXCLIEnvironment.service
        var updated = project
        if project.location == .disk {
            try service.saveLocal(project, text: text, original: source)
            let log = try await service.compileLocal(project)
            plan.finish(
                changed: text != source.text, plain: "saved and compiled \(project.pdfURL.path)",
                fields: ["pdfPath": .string(project.pdfURL.path), "log": .string(log)])
        } else {
            if updated.reviewBranch == nil {
                updated.reviewBranch = "latex/\(UUID().uuidString.lowercased())"
                try persist(updated)
            }
            updated.pullRequest = try await service.submit(updated, text: text, original: source)
            try persist(updated)
            plan.finish(
                changed: true, plain: "saved pull request #\(updated.pullRequest!) on GitHub",
                fields: ["project": json(updated)])
        }
    }
}

@MainActor struct LaTeXListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List source files and repositories in the LaTeX library.",
        discussion:
            "Reads project pointers without fetching source or changing files. Example: ed latex ls --json"
    )
    @Flag(name: .long, help: "Emit project pointers as JSON.") var json = false
    func run() async throws {
        try await execute {
            let projects = try LaTeXCLIEnvironment.store.load()
            if json {
                CLIOut.json(.array(projects.map(LaTeXCLI.json)))
            } else {
                CLIOut.out(
                    TextTable.render(
                        headers: ["ID", "PROJECT", "LOCATION", "SOURCE"],
                        rows: projects.map {
                            [$0.id.uuidString, $0.name, $0.location.rawValue, $0.sourcePath]
                        }))
            }
        }
    }
}

@MainActor struct LaTeXAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Register a local source or a GitHub source in the project library.",
        discussion: """
            Reads and validates the source before saving only its project pointer. For repositories,
            no clone or source file is written locally. Example: ed latex add --name Paper --file /tmp/main.tex --json
            """)
    @Option(name: .long, help: "Project display name.") var name: String
    @Option(name: .long, help: "Absolute local .tex path, mutually exclusive with --repo.")
    var file: String?
    @Option(name: .long, help: "GitHub owner/repository, requires --source.") var repo: String?
    @Option(name: .long, help: "Relative .tex path inside the GitHub repository.") var source:
        String?
    @Option(name: .long, help: "GitHub base branch, defaults to the repository's default branch.")
    var branch = ""
    @Option(
        name: .long,
        help: "tectonic or pdfLatex, defaults to tectonic on disk and pdfLatex on GitHub.")
    var compiler: String?
    @Flag(name: .long, help: "Emit the registered project as JSON.") var json = false
    func run() async throws {
        try await execute {
            guard (file != nil) != (repo != nil), repo == nil ? source == nil : source != nil,
                file == nil || branch.isEmpty
            else {
                throw CLIFailure.usage("use --file, or --repo with --source and optional --branch")
            }
            let location: LaTeXLocation = file == nil ? .github : .disk
            let engine = compiler ?? (location == .disk ? "tectonic" : "pdfLatex")
            guard let engine = LaTeXCompiler(rawValue: engine) else {
                throw CLIFailure.usage("compiler must be tectonic or pdfLatex")
            }
            let project = try await LaTeXCLIEnvironment.service.resolve(
                LaTeXProject(
                    name: name, location: location, sourcePath: file ?? source!, compiler: engine,
                    repository: repo ?? "", baseBranch: branch))
            _ = try await LaTeXCLI.source(project)
            let projects = try LaTeXCLIEnvironment.store.load()
            guard
                !projects.contains(where: {
                    $0.location == project.location && $0.sourcePath == project.sourcePath
                        && $0.repository == project.repository
                        && $0.baseBranch == project.baseBranch
                })
            else { throw CLIFailure.usage("this source is already in the LaTeX library") }
            try LaTeXCLI.persist(project)
            if json {
                CLIOut.json(LaTeXCLI.json(project))
            } else {
                CLIOut.out(project.id.uuidString)
            }
        }
    }
}

@MainActor struct LaTeXReadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read the complete source and its revision for a checked edit.",
        discussion:
            "Reads UTF-8 source from disk or GitHub without changing it. JSON includes the revision needed by write and edit. Example: ed latex read PROJECT --json"
    )
    @OptionGroup var options: LaTeXTargetOptions
    func run() async throws {
        try await execute {
            let project = try await LaTeXCLI.current(options.project)
            let source = try await LaTeXCLI.source(project)
            if options.json {
                CLIOut.json(
                    .object([
                        "project": LaTeXCLI.json(project),
                        "source": .string(source.text),
                        "revision": .string(LaTeXCLI.revision(source)),
                    ]))
            } else {
                CLIOut.raw(source.text)
            }
        }
    }
}

@MainActor struct LaTeXWriteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Replace a project's source from stdin and compile the saved revision.",
        discussion: """
            Reads raw UTF-8 stdin and verifies --revision. Without --yes it previews the source.
            With --yes it saves and compiles on disk, or writes a GitHub PR with a compiler workflow.
            Example: ed latex write PROJECT --revision REVISION --yes --json < main.tex
            """)
    @OptionGroup var options: LaTeXSaveOptions
    func run() async throws {
        try await execute {
            let project = try await LaTeXCLI.current(options.target.project)
            let source = try await LaTeXCLI.checkedSource(project, revision: options.revision)
            try await LaTeXCLI.save(
                project, source: source, text: LaTeXCLI.input(), options: options)
        }
    }
}

@MainActor struct LaTeXEditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit", abstract: "Apply checked literal replacements to a LaTeX source.",
        discussion: """
            Reads a JSON array from stdin with find, replace and expectedMatches for each edit.
            Replacements run in order and all must match before any source changes. Without --yes,
            previews the final source. With --yes, saves and compiles locally or submits a GitHub PR.
            Example: ed latex edit PROJECT --revision REVISION --yes --json < edits.json
            """)
    @OptionGroup var options: LaTeXSaveOptions
    func run() async throws {
        try await execute {
            let project = try await LaTeXCLI.current(options.target.project)
            let source = try await LaTeXCLI.checkedSource(project, revision: options.revision)
            let edits = try JSONDecoder().decode(
                [LaTeXTextEdit].self, from: Data(LaTeXCLI.input().utf8))
            let text = try LaTeXTextEdit.apply(edits, to: source.text)
            try await LaTeXCLI.save(project, source: source, text: text, options: options)
        }
    }
}

@MainActor struct LaTeXCompileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compile", abstract: "Rebuild a saved project's PDF locally or on GitHub.",
        discussion:
            "Reads the saved revision and writes a PDF beside a disk source, or reruns the repository's PDF workflow through Pukbot and returns its URL and build status. Source files do not change. Example: ed latex compile PROJECT --json"
    )
    @OptionGroup var options: LaTeXTargetOptions
    func run() async throws {
        try await execute {
            let project = try await LaTeXCLI.current(options.project)
            if project.location == .github {
                let build = try await LaTeXCLIEnvironment.service.rebuild(project)
                if options.json {
                    CLIOut.json(
                        .object([
                            "buildURL": .string(build.html_url), "status": .string(build.status),
                            "buildID": .int(build.id), "pdfPath": .null,
                        ]))
                } else {
                    CLIOut.out("\(build.status): \(build.html_url)")
                }
                return
            }
            let log = try await LaTeXCLIEnvironment.service.compileLocal(project)
            if options.json {
                CLIOut.json(
                    .object(["pdfPath": .string(project.pdfURL.path), "log": .string(log)]))
            } else {
                CLIOut.out(project.pdfURL.path)
            }
        }
    }
}

@MainActor struct LaTeXReviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Read the pull request, patch, and checks for native Quinjet review.",
        discussion:
            "Reads GitHub data for native Quinjet review without changing GitHub or cloning. Example: ed latex review PROJECT --json"
    )
    @OptionGroup var options: LaTeXTargetOptions
    func run() async throws {
        try await execute {
            let result = try await LaTeXCLIEnvironment.service.review(
                LaTeXCLI.project(options.project))
            let pr = result.pullRequest
            if options.json {
                CLIOut.json(
                    .object([
                        "pullRequest": .object([
                            "number": .int(pr.number), "title": .string(pr.title),
                            "state": .string(pr.state), "url": .string(pr.url),
                            "headOid": .string(pr.headOid), "mergeable": .string(pr.mergeable),
                        ]),
                        "diff": .string(result.diff),
                        "checks": .array(
                            result.checks.map {
                                .object([
                                    "name": .string($0.name), "workflow": .string($0.workflow),
                                    "status": .string($0.status), "link": .string($0.link),
                                ])
                            }),
                    ]))
            } else {
                CLIOut.out("\(pr.url)\n\(pr.state): \(pr.title)\n\(result.diff)")
            }
        }
    }
}

@MainActor struct LaTeXPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Read the current compiled PDF without storing repository artifacts.",
        discussion:
            "Reads the local PDF or current GitHub artifact into memory. --data with --json returns base64 PDF bytes, while the default reports availability. Example: ed latex preview PROJECT --data --json"
    )
    @OptionGroup var options: LaTeXTargetOptions
    @Flag(name: .long, help: "Include base64 PDF bytes in JSON, requires --json.") var data = false
    func run() async throws {
        try await execute {
            guard !data || options.json else { throw CLIFailure.usage("--data requires --json") }
            let project = try await LaTeXCLI.current(options.project)
            let bytes: Data?
            if project.location == .disk {
                bytes =
                    FileManager.default.fileExists(atPath: project.pdfURL.path)
                    ? try Data(contentsOf: project.pdfURL) : nil
            } else {
                bytes = try await LaTeXCLIEnvironment.service.previewPDF(project)
            }
            if options.json {
                CLIOut.json(
                    .object([
                        "available": .bool(bytes != nil), "bytes": .int(bytes?.count ?? 0),
                        "pdfPath": project.location == .disk ? .string(project.pdfURL.path) : .null,
                        "pdfBase64": data
                            ? bytes.map { .string($0.base64EncodedString()) } ?? .null : .null,
                    ]))
            } else {
                CLIOut.out(
                    bytes == nil
                        ? "PDF not available for the current revision"
                        : "PDF available: \(bytes!.count) bytes")
            }
        }
    }
}

@MainActor struct LaTeXMergeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge", abstract: "Squash merge the current pull request through Pukbot.",
        discussion:
            "Reads the project pointer and prints a plan. --yes changes GitHub by squash merging and deleting the branch; --auto waits for required checks. Example: ed latex merge PROJECT --auto --yes --json"
    )
    @OptionGroup var options: LaTeXTargetOptions
    @Flag(name: .long, help: "Merge when required checks pass.") var auto = false
    @Flag(name: .long, help: "Apply the merge plan on GitHub.") var yes = false
    func run() async throws {
        try await execute {
            let project = try LaTeXCLI.project(options.project)
            guard project.location == .github, let number = project.pullRequest else {
                throw CLIFailure.usage("this project has no GitHub pull request")
            }
            let plan = CLIDestructivePlan(
                action: auto ? "schedule squash merge" : "squash merge",
                targets: ["\(project.repository)#\(number)"], confirmed: yes, json: options.json)
            guard plan.shouldApply() else { return }
            try await LaTeXCLIEnvironment.service.merge(project, automatically: auto)
            plan.finish(
                changed: true, plain: auto ? "squash merge scheduled" : "pull request squash merged"
            )
        }
    }
}

@MainActor struct LaTeXRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Remove a project pointer from the LaTeX library.",
        discussion:
            "Reads the project pointer and prints a plan. --yes changes the library without deleting source files, repositories, or pull requests. Example: ed latex remove PROJECT --yes --json"
    )
    @OptionGroup var options: LaTeXTargetOptions
    @Flag(name: .long, help: "Remove the library entry after reviewing the plan.") var yes = false
    func run() async throws {
        try await execute {
            let project = try LaTeXCLI.project(options.project)
            let plan = CLIDestructivePlan(
                action: "remove LaTeX project pointer", targets: [project.name], confirmed: yes,
                json: options.json)
            guard plan.shouldApply() else { return }
            try LaTeXCLIEnvironment.store.save(
                LaTeXCLIEnvironment.store.load().filter { $0.id != project.id })
            plan.finish(changed: true, plain: "removed \(project.name) from the library")
        }
    }
}
