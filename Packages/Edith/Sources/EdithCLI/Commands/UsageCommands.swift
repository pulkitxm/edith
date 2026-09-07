import ArgumentParser
import EdithKit
import Foundation

struct UsageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage",
        abstract: "Agent usage, token counts, cost and rate limits.",
        discussion: """
            Numbers come from the same files the app's dashboard reads, so the CLI and
            the UI cannot disagree. `ed usage refresh` collects fresh data itself,
            whether or not the app is open.
            """,
        subcommands: [
            UsageLimitsCommand.self, UsageSummaryCommand.self, UsageDailyCommand.self,
            UsageModelsCommand.self, UsageProjectsCommand.self, UsageSourcesCommand.self,
            UsageMachinesCommand.self, UsageExportCommand.self, UsageRefreshCommand.self,
        ],
        defaultSubcommand: UsageSummaryCommand.self)
}

struct UsageWindow: ParsableArguments {
    @Option(help: "today, week, month or all.")
    var range: String = "all"

    @Option(name: .long, help: "Only this usage source. Repeat to include several.")
    var source: [String] = []

    @Option(
        name: .long,
        help: "Only this machine's agents, or local for this Mac. Repeat to include several.")
    var machine: [String] = []

    func resolved() throws -> UsageRange {
        guard let value = UsageRange(rawValue: range.lowercased()) else {
            throw CLIFailure.notFound(
                "no range named \(range)",
                hint: "ranges: " + UsageRange.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    func sources(in document: UsageDocument) throws -> Set<String>? {
        var chosen = try known(Set(source), in: document)
        for query in machine {
            let resolved = try? MachineResolver.machine(query)
            let matched = UsageMachineFilter.sources(
                matching: query, in: document, machineID: resolved?.id)
            guard !matched.isEmpty else {
                throw CLIFailure.notFound(
                    "no collected usage from a machine called \(query)",
                    hint: "run `ed usage machines` to see which machines have given usage")
            }
            chosen.formUnion(matched)
        }
        return chosen.isEmpty ? nil : chosen
    }

    private func known(_ requested: Set<String>, in document: UsageDocument) throws
        -> Set<String>
    {
        guard !requested.isEmpty else { return [] }
        let available = Set(document.sources ?? [])
        let unknown = requested.subtracting(available).sorted()
        guard unknown.isEmpty else {
            throw CLIFailure.notFound(
                "no usage source named " + unknown.joined(separator: ", "),
                hint: available.isEmpty
                    ? "run `ed usage refresh` first"
                    : "sources: " + available.sorted().joined(separator: ", "))
        }
        return requested
    }
}

struct UsageLimitsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "limits", abstract: "Session and weekly rate limits per provider.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Ask the app to poll the providers again before reporting.")
    var refresh = false

    func run() async throws {
        try await execute {
            if refresh {
                guard (try? CLIEnvironment.verifyAgentHandshake()) != nil else {
                    throw CLIFailure.unavailable(
                        "refreshing the rate limits needs the background agent",
                        hint: "run `ed agent restart` or enable the background agent in Settings")
                }
                let answered = await AppBridge.awaitReply(
                    IPC.Name.limitsUpdated, timeout: 20
                ) {
                    _ = try? CLIEnvironment.performAgentOperation(
                        UsageCollectionOperation.limitsRefresh.descriptor.id)
                }
                guard answered != nil else {
                    throw CLIFailure.unavailable(
                        "the background agent did not refresh the rate limits in time",
                        hint: "check `ed agent status` and retry")
                }
            }
            let providers = LimitsReport.providers()
            guard !providers.isEmpty else {
                throw CLIFailure.unavailable(
                    "no limit history yet",
                    hint: "enable the Agent Usage extension and let Edith poll once")
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        providers.map {
                            LimitsReport.json(
                                provider: $0.0, observedAt: $0.1, session: $0.2, week: $0.3)
                        }))
                return
            }
            let rows = providers.map { provider, observedAt, session, week in
                [
                    provider.label,
                    session.map { String(format: "%.1f%%", $0.percent) } ?? "-",
                    week.map { String(format: "%.1f%%", $0.percent) } ?? "-",
                    session?.resetsAt.map { resetText($0) } ?? "-",
                    JSONSerializer.iso.string(from: observedAt),
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["PROVIDER", "SESSION", "WEEKLY", "SESSION RESETS", "OBSERVED"],
                    rows: rows))
        }
    }

    private func resetText(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        return ByteFormatter.duration(seconds)
    }
}

struct UsageSummaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary", abstract: "Cost and tokens over a window.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageWindow

    func run() async throws {
        try await execute {
            let range = try window.resolved()
            let document = try UsageDocument.load()
            let days = UsageAnalysis.days(document, range: range)
            let sources = try window.sources(in: document)
            let totals = UsageAnalysis.totals(days, sources: sources)
            let bySource = UsageAnalysis.bySource(days, sources: sources)
            guard !json else {
                CLIOut.json(
                    .object([
                        "range": .string(range.rawValue),
                        "generatedAt": .optional(document.generatedAt),
                        "days": .int(days.count),
                        "totals": totals.json,
                        "bySource": .object(bySource.mapValues { $0.json }),
                    ]))
                return
            }
            CLIOut.out(String(format: "cost    $%.2f", totals.cost))
            CLIOut.out("tokens  \(Int(totals.tokens))")
            CLIOut.out("days    \(days.count)")
            let rows = bySource.keys.sorted().map { key in
                [
                    key, String(format: "%.2f", bySource[key]?.cost ?? 0),
                    String(Int(bySource[key]?.tokens ?? 0)),
                ]
            }
            CLIOut.out("")
            CLIOut.out(TextTable.render(headers: ["SOURCE", "COST", "TOKENS"], rows: rows))
        }
    }
}

struct UsageDailyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daily", abstract: "Per-day cost and tokens.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageWindow

    func run() async throws {
        try await execute {
            let range = try window.resolved()
            let document = try UsageDocument.load()
            let days = UsageAnalysis.byDay(
                UsageAnalysis.days(document, range: range),
                sources: try window.sources(in: document))
            guard !json else {
                CLIOut.json(
                    .array(
                        days.map { period, totals in
                            .object(["date": .string(period), "totals": totals.json])
                        }))
                return
            }
            let rows = days.map { period, totals in
                [period, String(format: "%.2f", totals.cost), String(Int(totals.tokens))]
            }
            CLIOut.out(TextTable.render(headers: ["DATE", "COST", "TOKENS"], rows: rows))
        }
    }
}

struct UsageModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models", abstract: "Cost and tokens per model.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageWindow

    func run() async throws {
        try await execute {
            let range = try window.resolved()
            let document = try UsageDocument.load()
            let models = UsageAnalysis.byModel(
                UsageAnalysis.days(document, range: range),
                sources: try window.sources(in: document))
            let ordered = UsageAnalysis.orderedModels(models)
            guard !json else {
                CLIOut.json(
                    .array(
                        ordered.map { name, totals in
                            .object(["model": .string(name), "totals": totals.json])
                        }))
                return
            }
            let rows = ordered.map { name, totals in
                [
                    UsageModelRow.displayName(name), String(format: "%.2f", totals.cost),
                    String(Int(totals.tokens)),
                ]
            }
            CLIOut.out(TextTable.render(headers: ["MODEL", "COST", "TOKENS"], rows: rows))
        }
    }
}

struct UsageProjectsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projects",
        abstract: "Inspect usage by GitHub repository.",
        subcommands: [
            UsageProjectsListCommand.self, UsageProjectsShowCommand.self,
            UsageProjectsOpenCommand.self, UsageProjectsCopyLinkCommand.self,
            UsageProjectsCopyChatCommand.self,
        ],
        defaultSubcommand: UsageProjectsListCommand.self)
}

struct UsageProjectsRange: ParsableArguments {
    @Option(help: "today, week, month or all.")
    var range: String = "all"

    func summaries() throws -> [UsageProjectSummary] {
        guard let value = UsageRange(rawValue: range.lowercased()) else {
            throw CLIFailure.notFound(
                "no range named \(range)",
                hint: "ranges: " + UsageRange.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let document = try UsageDocument.load()
        return UsageAnalysis.byProject(UsageAnalysis.days(document, range: value))
    }

    func resolve(_ query: String) throws -> (UsageProjectSummary, UsageProjectTarget) {
        let summaries = try summaries()
        do {
            let target = try UsageProjectOperationExecution.resolve(
                query, in: summaries.map(\.operationTarget))
            guard let summary = summaries.first(where: { $0.repositoryID == target.repositoryID })
            else {
                throw CLIFailure.notFound("no usage repository matches \(query)")
            }
            return (summary, target)
        } catch let error as UsageProjectOperationError {
            throw error.cliFailure
        }
    }
}

struct UsageProjectsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: UsageProjectOperation.list.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageProjectsRange

    @Option(help: "Show at most this many repositories.")
    var limit: Int?

    mutating func validate() throws {
        if let limit, limit <= 0 {
            throw ValidationError("--limit must be greater than zero")
        }
    }

    func run() async throws {
        try await execute {
            let allProjects = try window.summaries()
            let projects: [UsageProjectSummary]
            if let requested = self.limit {
                let limit = try ArgumentChecks.positive(requested, "--limit")
                projects = Array(allProjects.prefix(limit))
            } else {
                projects = allProjects
            }
            guard !json else {
                CLIOut.json(.array(projects.map(\.json)))
                return
            }
            let rows = projects.map { project in
                [
                    project.repositoryName, String(format: "%.2f", project.cost),
                    String(Int(project.tokens)),
                ]
            }
            CLIOut.out(TextTable.render(headers: ["REPOSITORY", "COST", "TOKENS"], rows: rows))
        }
    }
}

struct UsageProjectsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: UsageProjectOperation.show.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageProjectsRange

    @Argument(help: "Repository name, identity or URL.")
    var repository: String

    func run() async throws {
        try await execute {
            let (summary, _) = try window.resolve(repository)
            guard !json else {
                CLIOut.json(summary.json)
                return
            }
            CLIOut.out("repository  \(summary.repositoryName)")
            CLIOut.out("identity    \(summary.repositoryID)")
            CLIOut.out("link        \(summary.repositoryURL ?? "-")")
            CLIOut.out(String(format: "cost        %.2f", summary.cost))
            CLIOut.out("tokens      \(Int(summary.tokens))")
            CLIOut.out("")
            CLIOut.out(
                TextTable.render(
                    headers: [
                        "TYPE", "NAME", "CHAT ID", "SOURCE", "MACHINE", "PATH", "COST",
                        "TOKENS",
                    ],
                    rows: Self.hierarchyRows(summary)))
        }
    }

    static func hierarchyRows(_ summary: UsageProjectSummary) -> [[String]] {
        summary.folders.flatMap { folder in
            var rows = [
                row(
                    type: "folder", name: folder.folderName, machine: folder.machineName ?? "local",
                    path: folder.path, cost: folder.cost, tokens: folder.tokens)
            ]
            rows += folder.chats.map {
                chatRow($0, indent: "  ", machine: folder.machineName ?? "local")
            }
            for worktree in folder.worktrees {
                rows.append(
                    row(
                        type: "worktree", name: "  \(worktree.name)",
                        machine: folder.machineName ?? "local", path: nil,
                        cost: worktree.cost, tokens: worktree.tokens))
                rows += worktree.chats.map {
                    chatRow($0, indent: "    ", machine: folder.machineName ?? "local")
                }
            }
            return rows
        }
    }

    private static func chatRow(
        _ chat: UsageProjectChatSummary, indent: String, machine: String
    ) -> [String] {
        row(
            type: "chat", name: indent + chat.displayName, chatID: chat.id,
            source: chat.source, machine: machine, path: chat.path,
            cost: chat.cost, tokens: chat.tokens)
    }

    private static func row(
        type: String, name: String, chatID: String? = nil, source: String? = nil,
        machine: String, path: String?, cost: Double, tokens: Double
    ) -> [String] {
        [
            type, name, chatID ?? "-", source ?? "-", machine, path ?? "-",
            String(format: "%.2f", cost), String(Int(tokens)),
        ]
    }
}

struct UsageProjectsOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: UsageProjectOperation.openRepository.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageProjectsRange

    @Argument(help: "Repository name, identity or URL.")
    var repository: String

    func run() async throws {
        try await execute {
            let (_, target) = try window.resolve(repository)
            let result = try await performUsageProjectAction {
                try UsageProjectOperationExecution.openRepository(target)
            }
            render(result, json: json, message: "opened \(target.repositoryName)")
        }
    }
}

struct UsageProjectsCopyLinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-link",
        abstract: UsageProjectOperation.copyRepositoryLink.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageProjectsRange

    @Argument(help: "Repository name, identity or URL.")
    var repository: String

    func run() async throws {
        try await execute {
            let (_, target) = try window.resolve(repository)
            let result = try await performUsageProjectAction {
                try UsageProjectOperationExecution.copyRepositoryLink(target)
            }
            render(result, json: json, message: "copied \(result.value)")
        }
    }
}

struct UsageProjectsCopyChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-chat", abstract: UsageProjectOperation.copyChatID.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Chat identifier from the dashboard drilldown.")
    var chatID: String

    func run() async throws {
        try await execute {
            let result = try await performUsageProjectAction {
                try UsageProjectOperationExecution.copyChatID(chatID)
            }
            render(result, json: json, message: "copied \(result.value)")
        }
    }
}

private extension UsageProjectSummary {
    var operationTarget: UsageProjectTarget {
        UsageProjectTarget(
            repositoryID: repositoryID, repositoryName: repositoryName,
            repositoryURL: repositoryURL)
    }
}

private func render(_ result: UsageProjectOperationResult, json: Bool, message: String) {
    guard !json else {
        CLIOut.json(result.json)
        return
    }
    CLIOut.out(message)
}

private func performUsageProjectAction(
    _ action: @escaping @MainActor () throws -> UsageProjectOperationResult
) async throws -> UsageProjectOperationResult {
    do {
        return try await MainActor.run { try action() }
    } catch let error as UsageProjectOperationError {
        throw error.cliFailure
    }
}

extension UsageProjectOperationError {
    var cliFailure: CLIFailure {
        switch self {
        case .emptyQuery, .emptyChatID:
            .usage(localizedDescription)
        case .projectNotFound, .projectAmbiguous:
            .notFound(
                localizedDescription,
                hint: "run `ed usage projects list` to see repository names and identities")
        case .repositoryLinkUnavailable, .invalidRepositoryLink, .actionFailed:
            .unavailable(localizedDescription)
        }
    }
}

extension UsageProjectOperationResult {
    var json: JSONValue {
        .object([
            "operation": .string(operationID.rawValue),
            "repositoryID": .optional(repositoryID),
            "value": .string(value),
            "performed": .bool(true),
        ])
    }
}

struct UsageSourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources", abstract: "The agents that produced the usage history.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let document = try UsageDocument.load()
            let sources = document.sources ?? []
            guard !json else {
                CLIOut.json(
                    .array(
                        sources.map { id in
                            .object([
                                "id": .string(id),
                                "label": .optional(document.sourceMeta?[id]?.label),
                                "tool": .optional(document.sourceMeta?[id]?.tool),
                                "machine": .optional(document.sourceMeta?[id]?.machine),
                                "machineID": .optional(document.sourceMeta?[id]?.machineID),
                                "default": .bool(
                                    document.defaultSources?.contains(id) ?? false),
                            ])
                        }))
                return
            }
            let rows = sources.map { id in
                [
                    id, document.sourceMeta?[id]?.label ?? id,
                    document.sourceMeta?[id]?.tool ?? "",
                    document.sourceMeta?[id]?.machine ?? "this Mac",
                ]
            }
            CLIOut.out(
                TextTable.render(headers: ["ID", "LABEL", "TOOL", "MACHINE"], rows: rows))
        }
    }
}

struct UsageRefreshCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Re-collect usage data from every agent, here and on the machines.",
        discussion: """
            Runs the collection pipeline in this process, so it works whether or not the
            Edith app is open. If a refresh is already running somewhere else, this
            attaches to it and reports its progress instead of starting a second one.

            Machines counted towards usage are topped up first, if nothing has collected
            from them in the last half hour. `--machines` collects from all of them
            regardless, `--no-machines` leaves them alone.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Attach to a refresh that is already running instead of starting one.")
    var follow = false

    @Flag(
        name: .customLong("machines"),
        help: "Collect from every included machine, even when its usage is fresh.")
    var forceMachines = false

    @Flag(name: .customLong("no-machines"), help: "Skip machine usage collection.")
    var skipMachines = false

    mutating func validate() throws {
        guard !(forceMachines && skipMachines) else {
            throw ValidationError("--machines and --no-machines cannot be used together")
        }
    }

    func run() async throws {
        try await execute {
            let progress = CLIProgress.forCommand(json: json)
            let printer = UsageRefreshPrinter(progress: progress)
            let sink: @Sendable (UsageRefreshEvent) -> Void = { printer.show($0) }

            progress.header("EDITH · refresh usage · " + UsageRefreshPrinter.stamp(Date()))
            if !skipMachines, !follow {
                try await Self.topUpMachines(
                    force: forceMachines, progress: progress, sink: sink)
            }
            guard (try? CLIEnvironment.verifyAgentHandshake()) != nil else {
                throw CLIFailure.unavailable(
                    "usage refresh needs the background agent",
                    hint: "run `ed agent restart` or enable the background agent in Settings")
            }
            do {
                let refresh: UsageRefreshResult
                var attached = false
                if follow {
                    guard UsageRefreshRunner.isRunning else {
                        throw UsageCollectionOperationError.noRefreshRunning
                    }
                    progress.begin("following")
                    refresh = try await UsageRefreshFollower.follow(onEvent: sink)
                } else {
                    progress.begin("starting")
                    _ = try CLIEnvironment.performAgentOperation(
                        UsageCollectionOperation.refresh.descriptor.id)
                    if UsageRefreshRunner.isRunning {
                        attached = true
                        progress.note("a refresh is already running, attaching to it")
                    }
                    refresh = try await UsageRefreshFollower.follow(onEvent: sink)
                }
                progress.end()
                guard !json else {
                    CLIOut.json(Self.payload(result: refresh, followed: follow || attached))
                    return
                }
                CLIOut.out("usage refreshed")
            } catch let failure as UsageCollectionOperationError {
                progress.end()
                throw CLIFailure.unavailable(
                    failure.localizedDescription, hint: failure.hint)
            } catch let failure as UsageRefreshFailure {
                progress.end()
                progress.failure(failure.description)
                throw CLIFailure.unavailable(failure.description, hint: failure.hint)
            } catch {
                progress.end()
                throw error
            }
        }
    }

    private static func topUpMachines(
        force: Bool, progress: CLIProgress,
        sink: @escaping @Sendable (UsageRefreshEvent) -> Void
    ) async throws {
        let registry = MachineRegistry.machines()
        let due = MachineUsageRound.due(
            MachineUsageSelection.included(in: registry, CLIEnvironment.sharedDefaults),
            force: force,
            collectedAt: { MachineUsageStore.summary(machineID: $0)?.collectedAt })
        guard !due.isEmpty else { return }
        progress.begin(due.count == 1 ? "reaching \(due[0].name)" : "reaching the machines")
        let result = await UsageCollectionOperationExecution.collectMachines(
            UsageMachineCollectionInput(
                targets: due, registry: registry, dataDirectory: Repo.dataDir,
                timeout: MachineUsageCollector.defaultTimeout, verbose: false),
            includeSuccessfulMachines: false, store: CLIEnvironment.sharedDefaults,
            onEvent: sink,
            afterChange: { try? UsageAgentOperations.requestRefresh() })
        let round = result.round
        progress.end()
        if force, let failure = forcedMachineCollectionFailure(round) { throw failure }
        if round.skippedBecauseBusy {
            progress.note("another collection is already running, leaving the machines to it")
        }
    }

    static func forcedMachineCollectionFailure(_ round: MachineUsageRoundResult) -> CLIFailure? {
        if round.skippedBecauseBusy {
            return .unavailable(
                "machine usage collection is already running",
                hint: "retry after the active collection finishes")
        }
        guard !round.failures.isEmpty else { return nil }
        let detail = round.failures.map { "\($0.machine): \($0.reason)" }.joined(separator: "; ")
        return .unavailable("machine usage collection failed", hint: detail)
    }

    private static func payload(result: UsageRefreshResult, followed: Bool) -> JSONValue {
        .object([
            "completed": .bool(true),
            "followed": .bool(followed),
            "seconds": .double(result.seconds),
            "summary": .object(
                Dictionary(
                    uniqueKeysWithValues: result.summaries.map {
                        ($0.label, JSONValue.string($0.value))
                    }
                )),
            "phases": .array(
                result.events.compactMap { event in
                    guard case let .phase(name, detail, seconds) = event else { return nil }
                    return .object([
                        "name": .string(name), "detail": .string(detail),
                        "seconds": .double(seconds),
                    ])
                }),
        ])
    }
}

final class UsageRefreshPrinter: @unchecked Sendable {
    private let progress: CLIProgress
    private let lock = NSLock()
    private var sawSummary = false

    init(progress: CLIProgress) { self.progress = progress }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    func show(_ event: UsageRefreshEvent) {
        switch event {
        case let .phase(name, detail, seconds):
            progress.step(name, detail, seconds: seconds)
            progress.update(name)
        case let .note(text):
            progress.note(text)
            progress.update(text)
        case let .summary(label, value):
            openSummaries()
            progress.summary(label, value)
        case let .failure(text):
            progress.failure(text)
        case let .finished(seconds):
            progress.end()
            progress.done(String(format: "done in %.2fs", seconds))
        }
    }

    private func openSummaries() {
        lock.lock()
        let first = !sawSummary
        sawSummary = true
        lock.unlock()
        if first { progress.rule() }
    }
}
