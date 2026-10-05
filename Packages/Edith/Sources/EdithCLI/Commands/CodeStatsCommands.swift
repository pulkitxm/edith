import ArgumentParser
import EdithKit
import Foundation

public enum CodeStatsCLIEnvironment {
    public typealias Wait =
        @Sendable (UUID, @escaping @Sendable (String) -> Void) async throws -> Data

    nonisolated(unsafe) public static var client: @Sendable () -> CodeStatsAgentClient = {
        CodeStatsAgentClient()
    }
    nonisolated(unsafe) public static var wait: Wait = liveWait

    private static let liveWait: Wait = { id, report in
        try await AgentTaskClient().wait(id) { report($0.text) }
    }

    public static func reset() {
        client = { CodeStatsAgentClient() }
        wait = liveWait
    }
}

struct CodeStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "code-stats",
        abstract: "Report on the code you wrote across a mirror of your GitHub repositories.",
        discussion: """
            Reads and changes the Code Stats ability: the folder that mirrors every repository \
            you can reach on GitHub, the refresh schedule, the identities counted as you, and \
            the report the background agent builds from your own commits. A bare \
            `ed code-stats` shows the status.
            Example: ed code-stats status --json
            """,
        subcommands: [
            CodeStatsStatusCommand.self, CodeStatsRunCommand.self, CodeStatsCancelCommand.self,
            CodeStatsReportCommand.self, CodeStatsFolderCommand.self,
            CodeStatsScheduleCommand.self, CodeStatsIdentityCommand.self,
            CodeStatsAuthorsCommand.self,
        ],
        defaultSubcommand: CodeStatsStatusCommand.self)
}

enum CodeStatsCLI {
    static var defaults: UserDefaults { CLIEnvironment.sharedDefaults }

    static func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw failure(error) }
    }

    static func failure(_ error: Error) -> Error {
        if error is CLIFailure { return error }
        if let agent = error as? AgentError {
            switch agent.kind {
            case .unavailable, .incompatible:
                return CLIFailure.unavailable(
                    agent.message, hint: "open Edith so the background agent is running")
            case .refused:
                return CLIFailure.unavailable(agent.message)
            default:
                return CLIFailure(agent.message)
            }
        }
        if let failure = error as? AgentTaskFailure {
            return CLIFailure(failure.snapshot.failure ?? "the refresh failed")
        }
        return error
    }

    static func outcome(of run: CodeStatsActiveRun) async throws -> CodeStatsRunResult {
        do {
            let data = try await CodeStatsCLIEnvironment.wait(run.taskID) { CLIOut.note($0) }
            return try AgentPayload.decode(CodeStatsRunResult.self, from: data)
        } catch let failure as AgentTaskFailure {
            if let data = failure.result,
                let result = try? AgentPayload.decode(CodeStatsRunResult.self, from: data)
            {
                return result
            }
            return await recorded(run)
                ?? CodeStatsRunResult(
                    outcome: .failed(message: failure.snapshot.failure ?? "the refresh failed"),
                    startedAt: run.startedAt, finishedAt: Date())
        } catch is CancellationError {
            return await recorded(run)
                ?? CodeStatsRunResult(
                    outcome: .cancelled, startedAt: run.startedAt, finishedAt: Date())
        } catch {
            throw failure(error)
        }
    }

    static func recorded(_ run: CodeStatsActiveRun) async -> CodeStatsRunResult? {
        guard let status = try? await CodeStatsCLIEnvironment.client().status(),
            let last = status.state.lastRun, last.startedAt == run.startedAt
        else { return nil }
        return last
    }

    static func github(_ status: CodeStatsStatus) -> String {
        guard status.githubAvailable else { return "gh missing" }
        guard let issue = status.githubIssue, issue != .unavailable else { return "gh installed" }
        return issue.summary
    }

    static func line(_ label: String, _ value: String) -> String {
        label + ": " + value
    }

    static func print(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        CLIOut.out(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func schedule(_ schedule: CodeStatsSchedule) -> JSONValue {
        switch schedule {
        case .manual:
            .object(["kind": .string("manual"), "hour": .null, "weekday": .null])
        case .daily(let hour):
            .object(["kind": .string("daily"), "hour": .int(hour), "weekday": .null])
        case .weekly(let weekday, let hour):
            .object(["kind": .string("weekly"), "hour": .int(hour), "weekday": .int(weekday)])
        }
    }

    static func describe(_ schedule: CodeStatsSchedule) -> String {
        switch schedule {
        case .manual: "manual"
        case .daily(let hour): String(format: "daily at %02d:00", hour)
        case .weekly(let weekday, let hour):
            Calendar.current.weekdaySymbols[min(max(weekday, 1), 7) - 1]
                + String(format: " at %02d:00", hour)
        }
    }

    static func identity(_ identity: CodeStatsIdentity) -> JSONValue {
        .object([
            "emails": .strings(identity.emails), "substrings": .strings(identity.substrings),
        ])
    }

    static func storageState(_ storage: CodeStatsStorageStatus) -> String {
        switch storage {
        case .notConfigured: "notConfigured"
        case .ready: "ready"
        case .volumeDisconnected: "volumeDisconnected"
        case .missing: "missing"
        case .notDirectory: "notDirectory"
        case .notWritable: "notWritable"
        }
    }

    static func outcome(_ outcome: CodeStatsRunOutcome) -> String {
        switch outcome {
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .interrupted: "interrupted"
        case .volumeDisconnected: "volumeDisconnected"
        case .storageUnavailable: "storageUnavailable"
        case .failed: "failed"
        }
    }

    static func lastRun(_ run: CodeStatsRunResult?) -> JSONValue {
        guard let run else { return .null }
        return .object([
            "outcome": .string(outcome(run.outcome)),
            "summary": .string(run.outcome.summary),
            "startedAt": .date(run.startedAt), "finishedAt": .date(run.finishedAt),
            "repositories": .int(run.repositories), "synced": .int(run.synced),
            "failed": .int(run.failed), "errors": .strings(run.errors),
            "github": run.github.map {
                .object(["state": .string($0.state), "summary": .string($0.summary)])
            } ?? .null,
        ])
    }

    static func progress(_ progress: CodeStatsRunProgress?) -> JSONValue {
        guard let progress else { return .null }
        return .object([
            "phase": .string(progress.phase.rawValue), "completed": .int(progress.completed),
            "total": .int(progress.total), "inFlight": .strings(progress.inFlight),
            "synced": .int(progress.synced), "failed": .int(progress.failed),
            "skipped": .int(progress.skipped), "overallFraction": .double(progress.overallFraction),
            "startedAt": .date(progress.startedAt),
        ])
    }

    static func status(_ status: CodeStatsStatus) -> JSONValue {
        var storage: [String: JSONValue] = [
            "state": .string(storageState(status.storage)),
            "summary": .string(status.storage.summary),
        ]
        if case .ready(let free) = status.storage {
            storage["freeBytes"] = .optional(free.map(Int.init))
        }
        return .object([
            "folder": .optional(status.settings.folder),
            "storage": .object(storage),
            "schedule": schedule(status.settings.schedule),
            "includeForks": .bool(status.settings.includeForks),
            "includeArchived": .bool(status.settings.includeArchived),
            "identity": identity(status.settings.identity),
            "gitAvailable": .bool(status.gitAvailable),
            "githubAvailable": .bool(status.githubAvailable),
            "login": .optional(status.state.profile?.login),
            "running": .bool(status.isRunning),
            "taskID": .optional(status.state.active?.taskID.uuidString),
            "progress": progress(status.progress),
            "lastRun": lastRun(status.state.lastRun),
            "lastRunAt": .date(status.state.lastRunAt),
            "reportedAt": .date(status.state.reportedAt),
            "nextRunAt": .date(status.nextRunAt),
            "waitingFor": .optional(status.state.waitingFor),
        ])
    }

    static func lines(_ status: CodeStatsStatus) -> [String] {
        let date = { (value: Date?) in
            value.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
        }
        var lines = [
            CodeStatsCLI.line("folder", status.settings.folder ?? "not chosen"),
            CodeStatsCLI.line("storage", status.storage.summary),
            CodeStatsCLI.line("schedule", describe(status.settings.schedule)),
            CodeStatsCLI.line(
                "identities",
                status.settings.identity.isEmpty
                    ? "none yet" : status.settings.identity.labels.joined(separator: ", ")),
            CodeStatsCLI.line("git", status.gitAvailable ? "installed" : "missing"),
            CodeStatsCLI.line("github", github(status)),
            CodeStatsCLI.line("last run", status.state.lastRun?.outcome.summary ?? "never"),
            CodeStatsCLI.line("updated", date(status.state.reportedAt)),
            CodeStatsCLI.line("next run", date(status.nextRunAt)),
        ]
        if let progress = status.progress {
            lines.append(
                CodeStatsCLI.line(
                    "running",
                    "\(progress.phase.rawValue) \(progress.completed) of \(progress.total), "
                        + "\(Int(progress.overallFraction * 100))% overall"))
        }
        if let waiting = status.state.waitingFor {
            lines.append(CodeStatsCLI.line("waiting for", waiting))
        }
        return lines
    }
}

struct CodeStatsStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the mirror folder, schedule, last refresh and live progress.",
        discussion: """
            Reads the status the background agent keeps for Code Stats: whether the mirror \
            folder is ready or its drive is disconnected, the schedule, the last refresh and \
            the progress of one that is running. It does not change anything.
            Example: ed code-stats status --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let status = try await CodeStatsCLI.call {
                try await CodeStatsCLIEnvironment.client().status()
            }
            if json {
                CLIOut.json(CodeStatsCLI.status(status))
            } else {
                CodeStatsCLI.lines(status).forEach(CLIOut.out)
            }
        }
    }
}

struct CodeStatsRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Refresh the mirror and recount your commits in the background.",
        discussion: """
            Starts a refresh in the background agent, or joins the one already running: \
            new repositories are cloned, the rest are fetched, and your commits are counted \
            again. Changes the mirror folder and the stored report. Refuses when the folder \
            is not ready or git is missing. With --wait it prints progress on stderr, then \
            the outcome, and exits 1 unless the refresh completed.
            Example: ed code-stats run --wait
            """)

    @Flag(name: .long, help: "Wait for the refresh to finish, printing progress on stderr.")
    var wait = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let run = try await CodeStatsCLI.call {
                try await CodeStatsCLIEnvironment.client().start()
            }
            guard wait else {
                if json {
                    CLIOut.json(
                        .object([
                            "taskID": .string(run.taskID.uuidString),
                            "trigger": .string(run.trigger.rawValue),
                            "startedAt": .date(run.startedAt),
                        ]))
                } else {
                    CLIOut.out("refreshing code stats in the background, task \(run.taskID)")
                }
                return
            }
            let result = try await CodeStatsCLI.outcome(of: run)
            if json {
                CLIOut.json(CodeStatsCLI.lastRun(result))
            } else {
                CLIOut.out(
                    "refresh \(result.outcome.summary): \(result.repositories) repositories, "
                        + "\(result.synced) synced, \(result.failed) failed")
                if let issue = result.github { CLIOut.note(issue.summary) }
            }
            guard result.outcome == .completed else { throw ExitCode(ExitCodes.failure) }
        }
    }
}

struct CodeStatsCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancel the code stats refresh that is running.",
        discussion: """
            Asks the background agent to stop the refresh in progress. Repositories already \
            counted stay cached and the previous report is kept. Changes nothing when no \
            refresh is running.
            Example: ed code-stats cancel
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let status = try await CodeStatsCLI.call {
                try await CodeStatsCLIEnvironment.client().cancel()
            }
            if json {
                CLIOut.json(CodeStatsCLI.status(status))
            } else {
                CLIOut.out(status.isRunning ? "cancelling the refresh" : "no refresh is running")
            }
        }
    }
}

struct CodeStatsReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Print the code stats report for 30 days, 90 days, a year or all time.",
        discussion: """
            Reads the report the last refresh stored: commits, lines authored, active days, \
            streaks, momentum against the previous period, repositories, languages and \
            habits. It does not refresh or change anything.
            Example: ed code-stats report --range 90d --json
            """)

    @Option(name: .long, help: "Range to report: 30d, 90d, 1y or all.")
    var range = "30d"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard let parsed = CodeStatsRange(argument: range),
                CodeStatsRange.presets.contains(parsed)
            else {
                throw CLIFailure.usage(
                    "\(range) is not a report range", hint: "use 30d, 90d, 1y or all")
            }
            let report = try await CodeStatsCLI.call {
                try await CodeStatsCLIEnvironment.client().report(parsed)
            }
            guard let report else {
                throw CLIFailure.notFound(
                    "no code stats report exists yet", hint: "run ed code-stats run --wait")
            }
            if json {
                try CodeStatsCLI.print(report)
                return
            }
            let totals = report.totals
            var lines = [
                CodeStatsCLI.line("range", "\(report.startDay) to \(report.endDay)"),
                CodeStatsCLI.line("commits", "\(totals.commits)"),
                CodeStatsCLI.line(
                    "lines", "\(totals.authored) authored, \(totals.deleted) deleted"),
                CodeStatsCLI.line("active days", "\(totals.activeDays)"),
                CodeStatsCLI.line(
                    "streak", "\(totals.currentStreak) current, \(totals.longestStreak) longest"),
                CodeStatsCLI.line("repositories", "\(totals.repositories)"),
            ]
            if let change = report.momentum?.commitChange {
                lines.append(
                    CodeStatsCLI.line("momentum", String(format: "%+.0f%% commits", change)))
            }
            lines.append(
                CodeStatsCLI.line(
                    "languages",
                    report.languages.prefix(5).map(\.language).joined(separator: ", ")))
            lines.forEach(CLIOut.out)
        }
    }
}

struct CodeStatsFolderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folder",
        abstract: "Choose the folder that holds the repository mirror.",
        discussion: """
            Changes where Code Stats mirrors your repositories. The folder must exist. A \
            folder on an external drive under /Volumes is remembered while the drive is \
            unplugged, and refreshes wait for it to come back.
            Example: ed code-stats folder ~/GitHub
            """)

    @Argument(help: "Folder to use. A leading tilde expands to your home folder.")
    var path: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let selection: CodeStatsFolderSelection
            do {
                selection = try CodeStatsPreferences.selectFolder(
                    path, defaults: CodeStatsCLI.defaults,
                    homeDirectory: CLIEnvironment.homeDirectory)
            } catch let error as CodeStatsFolderError {
                throw CLIFailure.notFound(error.localizedDescription)
            }
            AppBridge.post(IPC.Name.settingsChanged)
            if json {
                CLIOut.json(
                    .object([
                        "path": .string(selection.path), "changed": .bool(selection.changed),
                        "external": .bool(selection.external),
                    ]))
            } else {
                CLIOut.out(
                    selection.changed
                        ? "code stats mirror set to \(selection.path)"
                        : "code stats already mirrors into \(selection.path)")
            }
        }
    }
}

struct CodeStatsScheduleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Choose how often code stats refresh on their own.",
        discussion: """
            Changes the refresh schedule: manual, daily at an hour, or weekly on a weekday \
            (1 is Sunday, 7 is Saturday) at an hour. Scheduling starts after the first \
            refresh, and a refresh missed while the Mac slept or the drive was unplugged \
            runs once as soon as it can.
            Example: ed code-stats schedule weekly --weekday 2 --hour 9
            """)

    @Argument(help: "manual, daily or weekly.")
    var kind: String

    @Option(name: .long, help: "Hour of the day from 0 to 23.")
    var hour: Int?

    @Option(name: .long, help: "Weekday from 1 (Sunday) to 7 (Saturday).")
    var weekday: Int?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard let kind = CodeStatsScheduleKind(rawValue: kind.lowercased()) else {
                throw CLIFailure.usage(
                    "\(self.kind) is not a schedule", hint: "use manual, daily or weekly")
            }
            if let hour, !CodeStatsPreferences.hours.contains(hour) {
                throw CLIFailure.usage("--hour must be between 0 and 23")
            }
            if let weekday, !CodeStatsPreferences.weekdays.contains(weekday) {
                throw CLIFailure.usage("--weekday must be between 1 and 7")
            }
            let defaults = CodeStatsCLI.defaults
            let current = CodeStatsPreferences.schedule(in: defaults)
            let currentHour: Int
            let currentWeekday: Int
            switch current {
            case .manual:
                currentHour = CodeStatsPreferences.defaultHour
                currentWeekday = CodeStatsPreferences.defaultWeekday
            case .daily(let hour):
                currentHour = hour
                currentWeekday = CodeStatsPreferences.defaultWeekday
            case .weekly(let weekday, let hour):
                currentHour = hour
                currentWeekday = weekday
            }
            let schedule: CodeStatsSchedule =
                switch kind {
                case .manual: .manual
                case .daily: .daily(hour: hour ?? currentHour)
                case .weekly: .weekly(weekday: weekday ?? currentWeekday, hour: hour ?? currentHour)
                }
            CodeStatsPreferences.setSchedule(schedule, in: defaults)
            AppBridge.post(IPC.Name.settingsChanged)
            if json {
                CLIOut.json(CodeStatsCLI.schedule(schedule))
            } else {
                CLIOut.out("code stats refresh \(CodeStatsCLI.describe(schedule))")
            }
        }
    }
}

struct CodeStatsIdentityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity",
        abstract: "List, add or remove the emails and name fragments counted as you.",
        discussion: """
            Reads and changes which commits count as yours. An email matches an author email \
            exactly; any other value matches when the author name or email contains it. An \
            empty list is filled from your GitHub profile on the next refresh.
            Example: ed code-stats identity add you@example.com
            """,
        subcommands: [
            CodeStatsIdentityListCommand.self, CodeStatsIdentityAddCommand.self,
            CodeStatsIdentityRemoveCommand.self,
        ],
        defaultSubcommand: CodeStatsIdentityListCommand.self)
}

struct CodeStatsIdentityListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the emails and name fragments counted as you.",
        discussion: """
            Reads the identities Code Stats uses to decide which commits are yours. It does \
            not change anything.
            Example: ed code-stats identity list --json
            """,
        aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let identity = CodeStatsPreferences.identity(in: CodeStatsCLI.defaults)
            if json {
                CLIOut.json(CodeStatsCLI.identity(identity))
            } else if identity.isEmpty {
                CLIOut.out("no identities yet; the next refresh adds your GitHub login")
            } else {
                identity.labels.forEach(CLIOut.out)
            }
        }
    }
}

struct CodeStatsIdentityAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Count commits with this email or name fragment as yours.",
        discussion: """
            Changes the identities: a value with an @ is an author email, anything else is a \
            fragment matched inside author names and emails. Adding a value already present \
            changes nothing.
            Example: ed code-stats identity add octocat
            """)

    @Argument(help: "An author email, or a fragment of a name or email.")
    var value: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIFailure.usage("the identity cannot be blank")
            }
            let defaults = CodeStatsCLI.defaults
            let changed = CodeStatsPreferences.addIdentity(value, in: defaults)
            AppBridge.post(IPC.Name.settingsChanged)
            CodeStatsIdentityRemoveCommand.report(
                value, changed: changed, verb: "added", defaults: defaults, json: json)
        }
    }
}

struct CodeStatsIdentityRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Stop counting commits with this email or name fragment as yours.",
        discussion: """
            Changes the identities by removing the value, matched without regard to case. \
            Commits already counted are recounted on the next refresh.
            Example: ed code-stats identity remove octocat
            """,
        aliases: ["rm"])

    @Argument(help: "The email or fragment to remove.")
    var value: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let defaults = CodeStatsCLI.defaults
            guard CodeStatsPreferences.removeIdentity(value, in: defaults) else {
                throw CLIFailure.notFound(
                    "\(value) is not an identity", hint: "list them with ed code-stats identity")
            }
            AppBridge.post(IPC.Name.settingsChanged)
            Self.report(value, changed: true, verb: "removed", defaults: defaults, json: json)
        }
    }

    static func report(
        _ value: String, changed: Bool, verb: String, defaults: UserDefaults, json: Bool
    ) {
        let identity = CodeStatsPreferences.identity(in: defaults)
        if json {
            CLIOut.json(
                .object([
                    "value": .string(value), "changed": .bool(changed),
                    "identity": CodeStatsCLI.identity(identity),
                ]))
        } else {
            CLIOut.out(changed ? "\(verb) \(value)" : "\(value) is already an identity")
        }
    }
}

struct CodeStatsAuthorsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "authors",
        abstract: "List the commit authors found in the mirror and which count as you.",
        discussion: """
            Reads every repository in the mirror folder and prints the most frequent author \
            names and emails, marking the ones your identities already count. It does not \
            change anything; add the missing ones with ed code-stats identity add.
            Example: ed code-stats authors --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let authors = try await CodeStatsCLI.call {
                try await CodeStatsCLIEnvironment.client().authors()
            }
            if json {
                CLIOut.json(
                    .array(
                        authors.map {
                            .object([
                                "name": .string($0.name), "email": .string($0.email),
                                "commits": .int($0.commits),
                                "countedAsYou": .bool($0.countedAsYou),
                            ])
                        }))
                return
            }
            guard !authors.isEmpty else {
                CLIOut.out("no commits found in the mirror yet")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["COMMITS", "YOU", "NAME", "EMAIL"],
                    rows: authors.map {
                        ["\($0.commits)", $0.countedAsYou ? "yes" : "", $0.name, $0.email]
                    }))
        }
    }
}
