import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor struct SEOCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seo",
        abstract: "Audit a site's pages, metadata, and Lighthouse scores.",
        discussion: """
            Reads and changes site-audit projects stored by the background agent, the same \
            projects as the Site Audit screen. A bare `ed seo` lists them.
            Example: ed seo ls --json
            """,
        subcommands: [
            SEOListCommand.self, SEOCreateCommand.self, SEORenameCommand.self,
            SEODeleteCommand.self, SEOShowCommand.self, SEOPagesCommand.self,
            SEOLighthouseCommand.self, SEOStartCommand.self, SEOStopCommand.self,
            SEORunCommand.self,
        ],
        defaultSubcommand: SEOListCommand.self)
}

@MainActor enum SEOCLI {
    static func identifier(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else {
            throw CLIFailure.usage(
                "\(raw) is not a project id", hint: "copy one from `ed seo ls`")
        }
        return id
    }

    static func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw failure(error) }
    }

    static func failure(_ error: Error) -> Error {
        if error is CLIFailure { return error }
        if let input = error as? SEOAuditInputError {
            let hint =
                input.message == "Select at least one page to audit."
                ? "refresh pages with `ed seo pages <id> --refresh`" : nil
            return CLIFailure(input.message, hint: hint)
        }
        return error
    }

    static func severity(_ raw: String) throws -> SEOAuditSeverity {
        guard let value = SEOAuditSeverity(rawValue: raw.lowercased()) else {
            throw CLIFailure.usage(
                "\(raw) is not a severity", hint: "use error, warning, or notice")
        }
        return value
    }

    static func platform(_ raw: String) throws -> SEOAuditSocialPlatform {
        guard
            let value = SEOAuditSocialPlatform.allCases.first(where: {
                $0.rawValue.lowercased() == raw.lowercased()
            })
        else {
            throw CLIFailure.usage(
                "\(raw) is not a social platform",
                hint: "use facebook, x, linkedin, slack, or discord")
        }
        return value
    }

    static func summary(_ item: SEOAuditProjectSummary) -> JSONValue {
        .object([
            "id": .string(item.id.uuidString),
            "name": .string(item.name),
            "baseURL": .string(item.baseURL),
            "updatedAt": .date(item.updatedAt),
            "latestRun": item.latestRun.map(runSummary) ?? .null,
        ])
    }

    static func project(_ project: SEOAuditProject, draft: SEOAuditDraft) -> JSONValue {
        .object([
            "id": .string(project.id.uuidString),
            "name": .string(project.name),
            "baseURL": .string(project.baseURL),
            "updatedAt": .date(project.updatedAt),
            "latestRun": project.latestRun.map { runSummary(SEOAuditRunSummary(run: $0)) } ?? .null,
            "draft": self.draft(
                draft, activeTaskIDs: SEOCLIEnvironment.service?.activeTaskIDs(project.id) ?? []),
        ])
    }

    static func draft(_ draft: SEOAuditDraft, activeTaskIDs: [UUID] = []) -> JSONValue {
        .object([
            "discoveredPageURLs": .strings(draft.discoveredPageURLs),
            "selectedPageURLs": .strings(draft.selectedPageURLs),
            "includeLighthouse": .bool(draft.includeLighthouse),
            "activeTaskIDs": .strings(activeTaskIDs.map(\.uuidString)),
        ])
    }

    static func run(
        _ run: SEOAuditRun, query: String, severity: SEOAuditSeverity?,
        platform: SEOAuditSocialPlatform
    ) -> JSONValue {
        let pages = SEOAuditSelection.matching(run.pages, query: query, severity: severity)
        return .object([
            "id": .string(run.id.uuidString),
            "state": .string(run.state.rawValue),
            "startedAt": .date(run.startedAt),
            "finishedAt": .date(run.finishedAt),
            "discoveredPageCount": .int(run.discoveredPageCount),
            "pageCount": .int(pages.count),
            "issueCount": .int(pages.reduce(0) { $0 + $1.issues.count }),
            "averageScore": .optional(run.averageScore),
            "error": .optional(run.error),
            "platform": .string(platform.rawValue),
            "pages": .array(pages.map { page($0, platform: platform) }),
        ])
    }

    static func launch(_ launch: SEOCLILaunch) -> JSONValue {
        .object([
            "projectID": .string(launch.request.projectID.uuidString),
            "runID": .string(launch.request.runID.uuidString),
            "state": .string(
                launch.snapshot?.state.rawValue ?? launch.project?.latestRun?.state.rawValue
                    ?? "queued"),
            "pageCount": .int(launch.request.urls.count),
            "lighthouse": .bool(launch.request.lighthouse),
            "taskID": .optional(launch.snapshot?.id.uuidString),
        ])
    }

    private static func runSummary(_ run: SEOAuditRunSummary) -> JSONValue {
        .object([
            "id": .string(run.id.uuidString),
            "state": .string(run.state.rawValue),
            "startedAt": .date(run.startedAt),
            "pageCount": .int(run.pageCount),
            "issueCount": .int(run.issueCount),
            "averageScore": .optional(run.averageScore),
        ])
    }

    private static func page(_ page: SEOAuditPageResult, platform: SEOAuditSocialPlatform)
        -> JSONValue
    {
        let card = SEOAuditSocialCard(metadata: page.metadata, platform: platform)
        return .object([
            "url": .string(page.url),
            "statusCode": .optional(page.statusCode),
            "issues": .array(
                page.issues.map {
                    .object([
                        "code": .string($0.code),
                        "severity": .string($0.severity.rawValue),
                        "title": .string($0.title),
                        "detail": .string($0.detail),
                    ])
                }),
            "scores": .object([
                "performance": .optional(page.scores.performance),
                "accessibility": .optional(page.scores.accessibility),
                "bestPractices": .optional(page.scores.bestPractices),
                "seo": .optional(page.scores.seo),
            ]),
            "social": .object([
                "platform": .string(platform.rawValue),
                "title": .string(card.title),
                "description": .string(card.detail),
                "imageURL": .optional(card.imageURL),
                "format": .string(card.formatLabel),
            ]),
        ])
    }
}

@MainActor struct SEOListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List saved site-audit projects.",
        discussion: """
            Reads project names, site URLs, and the latest run summary. It does not crawl or \
            change a project.
            Example: ed seo ls --json
            """,
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let projects = try await SEOCLI.call { try await SEOCLIController().list() }
            if json {
                CLIOut.json(.array(projects.map(SEOCLI.summary)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "URL", "RUN"],
                    rows: projects.map {
                        [
                            $0.name, $0.baseURL,
                            $0.latestRun.map { "\($0.state.rawValue) \($0.pageCount)" } ?? "none",
                        ]
                    }))
        }
    }
}

@MainActor struct SEOCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a site-audit project from a site URL.",
        discussion: """
            Writes a new empty project through the background agent. An omitted name uses the \
            site host, the same way the new-project sheet does.
            Example: ed seo create https://example.com --name Example --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Project name. Defaults to the site host.")
    var name: String?

    @Argument(help: "Site URL, with or without a scheme.")
    var url: String

    func run() async throws {
        try await execute {
            let project = try await SEOCLI.call {
                try await SEOCLIController().create(url: url, name: name)
            }
            let draft = (try? await SEOCLIController().draft(project.id)) ?? SEOAuditDraft()
            if json {
                CLIOut.json(SEOCLI.project(project, draft: draft))
            } else {
                CLIOut.out("\(project.id.uuidString)  \(project.name)")
            }
        }
    }
}

@MainActor struct SEORenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a site-audit project.",
        discussion: """
            Changes the saved project name. It does not recrawl the site. Refused while that \
            project's audit is running.
            Example: ed seo rename 00000000-0000-0000-0000-000000000000 Example --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Project id from `ed seo ls`.")
    var id: String

    @Argument(help: "New project name.")
    var name: String

    func run() async throws {
        try await execute {
            let projectID = try SEOCLI.identifier(id)
            let project = try await SEOCLI.call {
                try await SEOCLIController().rename(projectID, name: name)
            }
            if json {
                CLIOut.json(SEOCLI.summary(SEOAuditProjectSummary(project: project)))
            } else {
                CLIOut.out("\(project.id.uuidString)  \(project.name)")
            }
        }
    }
}

@MainActor struct SEODeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a site-audit project and its runs.",
        discussion: """
            Previews the project that would be removed. `--yes` writes the deletion of the \
            project file, its page assets, and its page selection. Refused while an audit is \
            running.
            Example: ed seo delete 00000000-0000-0000-0000-000000000000 --yes --json
            """,
        aliases: ["rm"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Delete the project. Without this, nothing is removed.")
    var yes = false

    @Argument(help: "Project id from `ed seo ls`.")
    var id: String

    func run() async throws {
        try await execute {
            let projectID = try SEOCLI.identifier(id)
            let project = try await SEOCLI.call { try await SEOCLIController().show(projectID) }
            let plan = CLIDestructivePlan(
                action: "delete site audit",
                targets: ["\(project.name) (\(project.id.uuidString))"],
                confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            try await SEOCLI.call { try await SEOCLIController().delete(projectID) }
            plan.finish(changed: true, plain: "deleted \(project.name)")
        }
    }
}

@MainActor struct SEOShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one site-audit project and its page selection.",
        discussion: """
            Reads the project, its latest run summary, and the saved page selection. It does \
            not crawl. Use `ed seo run` for page results.
            Example: ed seo show 00000000-0000-0000-0000-000000000000 --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Project id from `ed seo ls`.")
    var id: String

    func run() async throws {
        try await execute {
            let projectID = try SEOCLI.identifier(id)
            let controller = SEOCLIController()
            let project = try await SEOCLI.call { try await controller.show(projectID) }
            let draft = try await SEOCLI.call { try await controller.draft(projectID) }
            if json {
                CLIOut.json(SEOCLI.project(project, draft: draft))
                return
            }
            CLIOut.out(project.name)
            CLIOut.out(project.baseURL)
            CLIOut.out(
                "pages: \(draft.selectedPageURLs.count) of \(draft.discoveredPageURLs.count), "
                    + "lighthouse \(draft.includeLighthouse ? "on" : "off")")
            if let run = project.latestRun {
                CLIOut.out("latest: \(run.state.rawValue) \(run.pages.count) pages")
            }
        }
    }
}

@MainActor struct SEOPagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pages",
        abstract: "Discover a site's pages and choose which ones to audit.",
        discussion: """
            Reads the saved discovery list. When that list is empty, or when `--refresh` is \
            set, it crawls the site and selects newly found pages. `--all`, `--none`, `--only`, \
            `--add`, and `--remove` then change the selection the Site Audit checkboxes use.
            Example: ed seo pages 00000000-0000-0000-0000-000000000000 --refresh --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Crawl the site again before printing or choosing.")
    var refresh = false

    @Flag(name: .long, help: "Select every discovered page.")
    var all = false

    @Flag(name: .long, help: "Clear the page selection.")
    var none = false

    @Option(
        name: .long, parsing: .upToNextOption,
        help: "Replace the selection with these discovered page URLs.")
    var only: [String] = []

    @Option(
        name: .long, parsing: .upToNextOption,
        help: "Add these discovered page URLs to the selection.")
    var add: [String] = []

    @Option(
        name: .long, parsing: .upToNextOption,
        help: "Remove these page URLs from the selection.")
    var remove: [String] = []

    @Argument(help: "Project id from `ed seo ls`.")
    var id: String

    func run() async throws {
        try await execute {
            let edits = choice()
            guard edits.count <= 1 else {
                throw CLIFailure.usage(
                    "Pass only one of --all, --none, --only, --add, or --remove.")
            }
            let projectID = try SEOCLI.identifier(id)
            let controller = SEOCLIController()
            var draft = try await SEOCLI.call { try await controller.draft(projectID) }
            if refresh || draft.discoveredPageURLs.isEmpty {
                draft = try await SEOCLI.call { try await controller.discover(projectID) }
            }
            if let edit = edits.first {
                draft = try await SEOCLI.call { try await controller.choose(projectID, edit: edit) }
            }
            if json {
                CLIOut.json(
                    SEOCLI.draft(
                        draft,
                        activeTaskIDs: SEOCLIEnvironment.service?.activeTaskIDs(projectID) ?? []))
                return
            }
            for url in draft.discoveredPageURLs {
                let mark = draft.selectedPageURLs.contains(url) ? "selected" : "skipped"
                CLIOut.out("\(mark)  \(url)")
            }
        }
    }

    private func choice() -> [SEOAuditPageEdit] {
        var edits: [SEOAuditPageEdit] = []
        if all { edits.append(.all) }
        if none { edits.append(.none) }
        if !only.isEmpty { edits.append(.only(only)) }
        if !add.isEmpty { edits.append(.add(add)) }
        if !remove.isEmpty { edits.append(.remove(remove)) }
        return edits
    }
}

@MainActor struct SEOLighthouseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lighthouse",
        abstract: "Turn Lighthouse scoring on or off for the next audit.",
        discussion: """
            Writes the same include-Lighthouse switch as the project screen. It does not start \
            an audit. `ed seo start --lighthouse` or `--no-lighthouse` overrides it for one run.
            Example: ed seo lighthouse 00000000-0000-0000-0000-000000000000 on --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Project id from `ed seo ls`.")
    var id: String

    @Argument(help: "on scores pages with Lighthouse. off records metadata only.")
    var state: String

    func run() async throws {
        try await execute {
            let enabled: Bool
            switch state.lowercased() {
            case "on": enabled = true
            case "off": enabled = false
            default:
                throw CLIFailure.usage("\(state) is not on or off", hint: "pass on or off")
            }
            let projectID = try SEOCLI.identifier(id)
            let draft = try await SEOCLI.call {
                try await SEOCLIController().setLighthouse(projectID, enabled: enabled)
            }
            if json {
                CLIOut.json(
                    SEOCLI.draft(
                        draft,
                        activeTaskIDs: SEOCLIEnvironment.service?.activeTaskIDs(projectID) ?? []))
            } else {
                CLIOut.out("lighthouse \(draft.includeLighthouse ? "on" : "off")")
            }
        }
    }
}

@MainActor struct SEOStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start an audit of the selected pages.",
        discussion: """
            Queues the same background audit as the project's start button. It writes a new run \
            from the saved page selection and Lighthouse switch. `--wait` blocks until the run \
            finishes. Without it, the command returns once the run is queued.
            Example: ed seo start 00000000-0000-0000-0000-000000000000 --no-lighthouse --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Score this run with Lighthouse.")
    var lighthouse = false

    @Flag(name: .customLong("no-lighthouse"), help: "Skip Lighthouse for this run.")
    var noLighthouse = false

    @Flag(name: .long, help: "Wait until the audit finishes and print the queued run id.")
    var wait = false

    @Argument(help: "Project id from `ed seo ls`.")
    var id: String

    func run() async throws {
        try await execute {
            if lighthouse && noLighthouse {
                throw CLIFailure.usage("Pass only one of --lighthouse or --no-lighthouse.")
            }
            let override: Bool? = lighthouse ? true : (noLighthouse ? false : nil)
            let projectID = try SEOCLI.identifier(id)
            let launch = try await SEOCLI.call {
                try await SEOCLIController().start(projectID, lighthouse: override, wait: wait)
            }
            if json {
                CLIOut.json(SEOCLI.launch(launch))
            } else {
                CLIOut.out("run \(launch.request.runID.uuidString)")
            }
        }
    }
}

@MainActor struct SEOStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the audit running for a project.",
        discussion: """
            Previews the running audit that would be cancelled. `--yes` writes the cancellation \
            of that background task, the same stop button as the project screen. A finished run \
            is left in place.
            Example: ed seo stop 00000000-0000-0000-0000-000000000000 --yes --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Cancel the running audit. Without this, nothing is stopped.")
    var yes = false

    @Argument(help: "Project id from `ed seo ls`.")
    var id: String

    func run() async throws {
        try await execute {
            let projectID = try SEOCLI.identifier(id)
            let project = try await SEOCLI.call { try await SEOCLIController().show(projectID) }
            let plan = CLIDestructivePlan(
                action: "stop site audit", targets: [project.name], confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let cancelled = try await SEOCLI.call {
                try await SEOCLIController().stop(projectID)
            }
            plan.finish(
                changed: !cancelled.isEmpty, plain: "stopped \(project.name)",
                fields: ["cancelled": .strings(cancelled.map(\.uuidString))])
        }
    }
}

@MainActor struct SEORunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Show one audit run, including issues and social cards.",
        discussion: """
            Reads a saved run. `--offset 0` is the newest run and higher offsets step to older \
            ones. Omit `--severity` to include every issue. `--platform` picks the social card \
            the project screen previews: facebook, x, linkedin, slack, or discord.
            Example: ed seo run 00000000-0000-0000-0000-000000000000 --offset 0 --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .customLong("run"), help: "Run id. Overrides `--offset` when both are set.")
    var runID: String?

    @Option(name: .long, help: "0 is the newest run. 1 is the one before it.")
    var offset: Int = 0

    @Option(
        name: .long, help: "Keep pages with an issue of this severity: error, warning, or notice.")
    var severity: String?

    @Option(name: .long, help: "Keep pages whose URL or title contains this text.")
    var query: String = ""

    @Option(
        name: .long,
        help: "Social card to print: facebook, x, linkedin, slack, or discord.")
    var platform: String = "facebook"

    @Argument(help: "Project id from `ed seo ls`.")
    var id: String

    func run() async throws {
        try await execute {
            let projectID = try SEOCLI.identifier(id)
            let selectedRun = try runID.map(SEOCLI.identifier)
            let parsedSeverity = try severity.map(SEOCLI.severity)
            let parsedPlatform = try SEOCLI.platform(platform)
            guard offset >= 0 else {
                throw CLIFailure.usage("--offset cannot be negative", hint: "pass 0 or more")
            }
            let audit = try await SEOCLI.call {
                try await SEOCLIController().run(projectID, runID: selectedRun, offset: offset)
            }
            if json {
                CLIOut.json(
                    SEOCLI.run(
                        audit, query: query, severity: parsedSeverity, platform: parsedPlatform))
                return
            }
            let pages = SEOAuditSelection.matching(
                audit.pages, query: query, severity: parsedSeverity)
            CLIOut.out("\(audit.state.rawValue)  \(pages.count) pages")
            for page in pages {
                let card = SEOAuditSocialCard(metadata: page.metadata, platform: parsedPlatform)
                CLIOut.out("\(page.url)  \(page.issues.count) issues")
                CLIOut.out("  \(parsedPlatform.rawValue): \(card.title) (\(card.formatLabel))")
            }
        }
    }
}
