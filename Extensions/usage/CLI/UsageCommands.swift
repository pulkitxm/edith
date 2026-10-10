import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
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
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev",
        subcommands: [
            UsageLimitsCommand.self, UsageAlertsCommand.self, UsageSummaryCommand.self,
            UsageDailyCommand.self, UsageModelsCommand.self, UsageProjectsCommand.self,
            UsageAttributionCommand.self, UsageSourcesCommand.self,
            UsageMachinesCommand.self, UsageExportCommand.self, UsageRefreshCommand.self,
            UsageStatusLineCommand.self,
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

    @MainActor func sources(in document: UsageDocument) throws -> Set<String>? {
        var chosen = try known(Set(source), in: document)
        for query in machine {
            let resolved = try? UsageCLIMachines.resolve(query)
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
        commandName: "limits", abstract: "Show included rate limits per provider.",
        discussion: """
            Prints the most recent rate limit observation for each provider Edith
            tracks.

            Changes the state this command names.

            ed usage limits
            ed usage limits --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Ask the app to poll the providers again before reporting.")
    var refresh = false

    @MainActor func run() async throws {
        try await execute {
            if refresh {
                try await UsageCLIEnvironment.refreshLimits()
            }
            let providers = LimitsReport.providers()
            guard !providers.isEmpty else {
                throw CLIFailure.unavailable(
                    "no limit history yet",
                    hint: "enable the Agent Usage extension and let Edith poll once")
            }
            guard !json else {
                CLIOut.json(.array(providers.map(LimitsReport.json)))
                return
            }
            let rows = providers.flatMap { observation -> [[String]] in
                var slots: [(LimitWindowSlot, LimitWindow?)] =
                    observation.provider == .grok
                    ? [(.week, observation.week)]
                    : [(.session, observation.session), (.week, observation.week)]
                if observation.provider == .claude, let fable = observation.fable {
                    slots.append((.fable, fable))
                }
                var lines = slots.map { slot, window in
                    [
                        observation.provider.label,
                        slot.title(for: observation.provider, period: window?.period),
                        window.map { String(format: "%.1f%%", $0.percent) } ?? "-",
                        window?.resetsAt.map { resetText($0) } ?? "-",
                        JSONSerializer.iso.string(from: observation.observedAt),
                    ]
                }
                if let allowance = observation.grok, allowance.products.count > 1 {
                    lines += allowance.products.map { product in
                        [
                            observation.provider.label,
                            product.name,
                            String(format: "%.1f%%", product.percent),
                            observation.week?.resetsAt.map { resetText($0) } ?? "-",
                            JSONSerializer.iso.string(from: observation.observedAt),
                        ]
                    }
                }
                return lines
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["PROVIDER", "LIMIT", "USED", "RESETS", "OBSERVED"],
                    rows: rows))
            for observation in providers {
                guard let extra = observation.grok?.extraLine else { continue }
                CLIOut.out("\(observation.provider.label): \(extra)")
            }
        }
    }

    private func resetText(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        return UsageCLIDuration.format(seconds)
    }
}

struct UsageAlertsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "alerts",
        abstract: "What each tracked limit window would alert about now, and why.",
        discussion: """
            Shows, for every limit window Edith tracks, the burn rate, the projected cap
            time and which limit alert the planner would send right now, with the
            reason.

            Changes the state this command names.

            ed usage alerts
            ed usage alerts --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            guard !LimitsHistory.availableProviders().isEmpty else {
                throw CLIFailure.unavailable(
                    "no limit history yet",
                    hint: "enable the Agent Usage extension and let Edith poll once")
            }
            let clock = LimitAlertClock()
            let verdicts = LimitAlertInspector.inspect(clock: clock)
            let enabled = LimitAlertSettings.fromDefaults(SharedDefaults.store).master
            guard !json else {
                CLIOut.json(
                    .object([
                        "enabled": .bool(enabled),
                        "jevConfigured": .bool(
                            SurfaceHostContext.current?.activeIDs.contains("jev") == true),
                        "windows": .array(verdicts.map(LimitsReport.alert)),
                    ]))
                return
            }
            let rows = verdicts.map { verdict in
                let a = verdict.assessment
                return [
                    a.target.label, String(format: "%.0f%%", a.window.percent),
                    a.window.resetsAt.map(clock.moment) ?? "-",
                    a.burn.map { String(format: "%.1f%%/h", $0.perHour) } ?? "-",
                    a.active ? a.projectedCapAt.map(clock.moment) ?? "-" : "idle",
                    verdict.alert?.kind.rawValue ?? "none", verdict.reason,
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["WINDOW", "USED", "RESETS", "BURN", "CAP AROUND", "ALERT", "WHY"],
                    rows: rows))
            if !enabled { CLIOut.out("Limit alerts are off; this is what they would send.") }
        }
    }
}

struct UsageSummaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary", abstract: "Show cost and tokens over a window.",
        discussion: """
            Totals cost and tokens over a window, then breaks the same totals down by
            source.

            Changes the state this command names.

            ed usage summary
            ed usage summary --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageWindow

    @MainActor func run() async throws {
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
        commandName: "daily", abstract: "Show per-day cost and tokens.",
        discussion: """
            One row per day in the window, cost and tokens.

            Changes the state this command names.

            ed usage daily
            ed usage daily --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageWindow

    @MainActor func run() async throws {
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
        commandName: "models", abstract: "Show cost and tokens per model.",
        discussion: """
            Tokens and attributable cost per model, plus any exact provider cost that
            cannot be assigned to one model.

            Changes the state this command names.

            ed usage models
            ed usage models --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageWindow

    @MainActor func run() async throws {
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
        discussion: """
            Inspect the repository hierarchy behind the dashboard project drilldown.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed usage projects list
            """,
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
        commandName: "list", abstract: UsageProjectOperation.list.descriptor.summary,
        discussion: """
            List cost and tokens per repository, with matching folders grouped under
            their stable repository identity.

            Reads the saved records in stored order. Does not change them.

            ed usage projects list
            ed usage projects list --json
            """, )

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

    @MainActor func run() async throws {
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
        commandName: "show", abstract: UsageProjectOperation.show.descriptor.summary,
        discussion: """
            Show one repository and its full usage drilldown.

            Reads one record and its live facts. Does not change them.

            ed usage projects show repository
            ed usage projects show repository --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageProjectsRange

    @Argument(help: "Repository name, identity or URL.")
    var repository: String

    @MainActor func run() async throws {
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
            let note = folder.attribution.map { " (attributed by \($0 == "jev" ? "Jev" : $0))" }
            var rows = [
                row(
                    type: "folder", name: folder.folderName + (note ?? ""),
                    machine: folder.machineName ?? "local", path: folder.path, cost: folder.cost,
                    tokens: folder.tokens)
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
        commandName: "open", abstract: UsageProjectOperation.openRepository.descriptor.summary,
        discussion: """
            Open one usage repository in the default browser.

            Changes this Mac by opening the target in an app or a browser.

            ed usage projects open repository
            ed usage projects open repository --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageProjectsRange

    @Argument(help: "Repository name, identity or URL.")
    var repository: String

    @MainActor func run() async throws {
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
        abstract: UsageProjectOperation.copyRepositoryLink.descriptor.summary,
        discussion: """
            Copy one usage repository link to the macOS pasteboard.

            Changes the state this command names.

            ed usage projects copy-link repository
            ed usage projects copy-link repository --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @OptionGroup var window: UsageProjectsRange

    @Argument(help: "Repository name, identity or URL.")
    var repository: String

    @MainActor func run() async throws {
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
        commandName: "copy-chat", abstract: UsageProjectOperation.copyChatID.descriptor.summary,
        discussion: """
            Copy a chat identifier from the dashboard repository drilldown.

            Changes the state this command names.

            ed usage projects copy-chat chatid
            ed usage projects copy-chat chatid --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Chat identifier from the dashboard drilldown.")
    var chatID: String

    @MainActor func run() async throws {
        try await execute {
            let result = try await performUsageProjectAction {
                try UsageProjectOperationExecution.copyChatID(chatID)
            }
            render(result, json: json, message: "copied \(result.value)")
        }
    }
}

extension UsageProjectSummary {
    fileprivate var operationTarget: UsageProjectTarget {
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
        commandName: "sources", abstract: "Show the agents that produced the usage history.",
        discussion: """
            Lists the agents that produced the history, which is where the ids
            `--source` expects come from.

            Changes the state this command names.

            ed usage sources
            ed usage sources --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
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
            Runs the owning Usage engine collection pipeline. If a refresh is already
            running, this attaches to it and reports its progress instead of starting
            a second one.

            Machines counted towards usage are collected at the same time as this Mac's
            own agents, if nothing has collected from them in the last half hour.
            `--machines` collects from all of them first and stops if any fails,
            `--no-machines` leaves them alone.
            Changes the state this command names.

            ed usage refresh
            ed usage refresh --json
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

    @MainActor func run() async throws {
        try await execute {
            let result = try await UsageCLIEnvironment.refresh(
                follow: follow,
                policy: forceMachines ? .all : skipMachines ? .skip : .due, json: json)
            if json { CLIOut.json(result) } else { CLIOut.out("usage refreshed") }
        }
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
        case .phase(let name, let detail, let seconds):
            progress.step(name, detail, seconds: seconds)
            progress.update(name)
        case .note(let text):
            progress.note(text)
            progress.update(text)
        case .summary(let label, let value):
            openSummaries()
            progress.summary(label, value)
        case .failure(let text):
            progress.failure(text)
        case .finished(let seconds):
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
