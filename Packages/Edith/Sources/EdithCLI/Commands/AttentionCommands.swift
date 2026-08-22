import ArgumentParser
import EdithKit
import Foundation

struct AttentionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attention",
        abstract: "Local attention, application, website, music and focus data.",
        subcommands: [
            AttentionStatusCommand.self, AttentionSummaryCommand.self,
            AttentionTimelineCommand.self, AttentionMusicCommand.self,
            AttentionCategoriesCommand.self, AttentionFocusCommand.self,
            AttentionDoctorCommand.self,
        ],
        defaultSubcommand: AttentionStatusCommand.self)
}

enum AttentionCLI {
    static var repository: AttentionRepository { AttentionRepository() }

    static func interval(_ raw: String, now: Date = Date(), calendar: Calendar = .current) throws
        -> DateInterval
    {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let today = calendar.startOfDay(for: now)
        switch value {
        case "today": return DateInterval(start: today, end: now)
        case "yesterday":
            let start = calendar.date(byAdding: .day, value: -1, to: today)!
            return DateInterval(start: start, end: today)
        case "week", "7d":
            let start = calendar.date(byAdding: .day, value: -6, to: today)!
            return DateInterval(start: start, end: now)
        case "month", "30d":
            let start = calendar.date(byAdding: .day, value: -29, to: today)!
            return DateInterval(start: start, end: now)
        case "all": return DateInterval(start: .distantPast, end: now)
        default:
            guard value.count > 1, let unit = value.last,
                let amount = Int(value.dropLast()), amount > 0
            else { throw invalidRange(raw) }
            let seconds: TimeInterval
            switch unit {
            case "h": seconds = Double(amount) * 3_600
            case "d": seconds = Double(amount) * 86_400
            case "w": seconds = Double(amount) * 604_800
            default: throw invalidRange(raw)
            }
            return DateInterval(start: now.addingTimeInterval(-seconds), end: now)
        }
    }

    static func duration(_ raw: String) throws -> TimeInterval {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 1, let unit = value.last, let amount = Double(value.dropLast()),
            amount > 0
        else { throw CLIFailure.usage("\(raw) is not a duration like 25m, 1h or 90m") }
        switch unit {
        case "m": return amount * 60
        case "h": return amount * 3_600
        default: throw CLIFailure.usage("\(raw) is not a duration like 25m, 1h or 90m")
        }
    }

    static func summary(range: String, now: Date = Date()) throws -> AttentionSummary {
        let interval = try interval(range, now: now)
        let repository = repository
        return AttentionAnalyzer().summary(
            events: repository.events(from: interval.start, to: interval.end),
            settings: repository.loadSettings(), from: interval.start, to: interval.end)
    }

    static func summaryJSON(_ summary: AttentionSummary) -> JSONValue {
        .object([
            "from": .date(summary.from),
            "to": .date(summary.to),
            "activeSeconds": .double(summary.activeDuration),
            "idleSeconds": .double(summary.idleDuration),
            "focusedSeconds": .double(summary.focusedDuration),
            "communicationSeconds": .double(summary.communicationDuration),
            "entertainmentSeconds": .double(summary.entertainmentDuration),
            "focusPercent": .double(percent(summary.focusedDuration, of: summary.activeDuration)),
            "entertainmentPercent": .double(
                percent(summary.entertainmentDuration, of: summary.activeDuration)),
            "contextSwitches": .int(summary.contextSwitches),
            "entities": .array(summary.entities.map(entityJSON)),
            "music": .array(summary.music.map(musicJSON)),
        ])
    }

    static func eventJSON(_ event: AttentionEvent) -> JSONValue {
        .object([
            "id": .string(event.id),
            "startedAt": .date(event.startedAt),
            "durationSeconds": .double(event.duration),
            "source": .string(event.source.rawValue),
            "presence": .string(event.presence.rawValue),
            "appName": .optional(event.appName),
            "bundleID": .optional(event.bundleID),
            "windowTitle": .optional(event.windowTitle),
            "url": .optional(event.url),
            "domain": .optional(event.domain),
            "browserProfile": .optional(event.browserProfile),
            "media": event.media.map(mediaJSON) ?? .null,
        ])
    }

    static func entityJSON(_ entity: AttentionEntity) -> JSONValue {
        .object([
            "id": .string(entity.id),
            "name": .string(entity.name),
            "categoryID": .string(entity.category.id),
            "category": .string(entity.category.name),
            "categoryKind": .string(entity.category.kind.rawValue),
            "source": .string(entity.source.rawValue),
            "durationSeconds": .double(entity.duration),
            "faviconURL": .optional(entity.faviconURL),
        ])
    }

    static func musicJSON(_ item: AttentionMusicSummary) -> JSONValue {
        .object([
            "id": .string(item.id),
            "title": .string(item.title),
            "artist": .optional(item.artist),
            "album": .optional(item.album),
            "service": .string(item.service),
            "durationSeconds": .double(item.duration),
        ])
    }

    static func mediaJSON(_ media: AttentionMedia) -> JSONValue {
        .object([
            "title": .string(media.title),
            "artist": .optional(media.artist),
            "album": .optional(media.album),
            "service": .string(media.service),
            "kind": .string(media.kind),
            "playing": .bool(media.playing),
        ])
    }

    static func percent(_ value: TimeInterval, of total: TimeInterval) -> Double {
        guard total > 0 else { return 0 }
        return value / total * 100
    }

    static func clock(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func save(settings: AttentionSettings) throws {
        try repository.saveSettings(settings)
        ConfigStore.announceChange()
    }

    static func categorize(
        entity: String, category value: String, name: String?
    ) throws -> AttentionIdentityRule {
        var settings = repository.loadSettings()
        guard
            let category = settings.categories.first(where: {
                $0.id.caseInsensitiveCompare(value) == .orderedSame
                    || $0.name.caseInsensitiveCompare(value) == .orderedSame
            })
        else {
            throw CLIFailure.notFound(
                "there is no attention category named \(value)",
                hint: "run `ed attention categories ls`")
        }
        let parts = entity.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["identity", "app", "web"].contains(parts[0]),
            !parts[1].isEmpty
        else {
            throw CLIFailure.usage(
                "\(entity) is not an entity ID",
                hint: "use an id from `ed attention summary --json`")
        }
        let type = parts[0]
        let value = parts[1]
        let index: Int?
        switch type {
        case "identity": index = settings.rules.firstIndex { $0.id == value }
        case "app": index = settings.rules.firstIndex { $0.bundleIDs.contains(value) }
        default:
            index = settings.rules.firstIndex {
                $0.domains.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            }
        }
        if let index {
            settings.rules[index].categoryID = category.id
            if let name, !name.isEmpty { settings.rules[index].name = name }
            try save(settings: settings)
            return settings.rules[index]
        }
        let inferredName = name?.isEmpty == false ? name! : value
        let rule = AttentionIdentityRule(
            name: inferredName, categoryID: category.id,
            bundleIDs: type == "app" ? [value] : [], domains: type == "web" ? [value] : [])
        settings.rules.append(rule)
        try save(settings: settings)
        return rule
    }

    private static func invalidRange(_ raw: String) -> CLIFailure {
        CLIFailure.usage(
            "\(raw) is not an attention range",
            hint: "use today, yesterday, 24h, 7d, 30d, week, month or all")
    }
}

struct AttentionStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show attention tracking, data and focus state.")

    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let repository = AttentionCLI.repository
            let settings = repository.loadSettings()
            let focus = repository.activeFocus()
            let events = repository.events(
                from: Date().addingTimeInterval(-86_400), to: Date())
            let browserServerReady: Bool
            if settings.isEnabled, settings.browserTrackingEnabled {
                browserServerReady = await AttentionIngestionServer.isHealthy(
                    port: settings.serverPort, timeout: 0.5)
            } else {
                browserServerReady = false
            }
            if json {
                CLIOut.json(
                    .object([
                        "enabled": .bool(settings.isEnabled),
                        "trackingEnabled": .bool(settings.trackingEnabled),
                        "browserTrackingEnabled": .bool(settings.browserTrackingEnabled),
                        "browserServerReady": .bool(browserServerReady),
                        "privacyLevel": .string(settings.privacyLevel.rawValue),
                        "windowTitlesEnabled": .bool(settings.windowTitlesEnabled),
                        "iCloudBackupEnabled": .bool(settings.iCloudBackupEnabled),
                        "eventsLast24Hours": .int(events.count),
                        "historySites": .int(repository.historyVisits().count),
                        "helperRunning": .bool(AppBridge.helperIsRunning),
                        "focus": focus.map(focusJSON) ?? .null,
                    ]))
                return
            }
            CLIOut.out("attention: \(settings.isEnabled ? "on" : "off")")
            CLIOut.out(
                "application tracking: \(settings.isEnabled && settings.trackingEnabled ? "on" : "off")"
            )
            CLIOut.out(
                "browser tracking: \(settings.isEnabled && settings.browserTrackingEnabled ? "on" : "off")"
            )
            CLIOut.out("privacy: \(settings.privacyLevel.rawValue)")
            CLIOut.out("events in last 24h: \(events.count)")
            CLIOut.out("history inventory: \(repository.historyVisits().count) sites")
            CLIOut.out("focus: \(focus?.name ?? "none")")
        }
    }

    private func focusJSON(_ focus: AttentionFocusSession) -> JSONValue {
        .object([
            "id": .string(focus.id), "name": .string(focus.name),
            "startedAt": .date(focus.startedAt),
            "plannedSeconds": .double(focus.plannedDuration),
        ])
    }
}

struct AttentionSummaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary", abstract: "Summarize focus, distraction and top destinations.")

    @Option(help: "Window: today, yesterday, 24h, 7d, 30d, week, month or all.")
    var range = "today"
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let summary = try AttentionCLI.summary(range: range)
            if json {
                CLIOut.json(AttentionCLI.summaryJSON(summary))
                return
            }
            CLIOut.out("active: \(AttentionCLI.clock(summary.activeDuration))")
            CLIOut.out(
                "focused: \(AttentionCLI.clock(summary.focusedDuration)) (\(Int(AttentionCLI.percent(summary.focusedDuration, of: summary.activeDuration).rounded()))%)"
            )
            CLIOut.out(
                "entertainment: \(AttentionCLI.clock(summary.entertainmentDuration)) (\(Int(AttentionCLI.percent(summary.entertainmentDuration, of: summary.activeDuration).rounded()))%)"
            )
            CLIOut.out("idle: \(AttentionCLI.clock(summary.idleDuration))")
            CLIOut.out("context switches: \(summary.contextSwitches)")
            CLIOut.out("")
            CLIOut.out(
                TextTable.render(
                    headers: ["ENTITY", "CATEGORY", "TIME", "ID"],
                    rows: summary.entities.prefix(15).map {
                        [$0.name, $0.category.name, AttentionCLI.clock($0.duration), $0.id]
                    }))
        }
    }
}

struct AttentionTimelineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timeline", abstract: "List raw observed attention events.")

    @Option(help: "Window: today, yesterday, 24h, 7d, 30d, week, month or all.")
    var range = "today"
    @Option(help: "Maximum events, newest first. Pass 0 for all.") var limit = 100
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let interval = try AttentionCLI.interval(range)
            let all = AttentionCLI.repository.events(from: interval.start, to: interval.end)
                .reversed()
            let events = limit == 0 ? Array(all) : Array(all.prefix(limit))
            if json {
                CLIOut.json(.array(events.map(AttentionCLI.eventJSON)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["START", "TIME", "STATE", "SOURCE", "DESTINATION"],
                    rows: events.map {
                        [
                            JSONSerializer.iso.string(from: $0.startedAt),
                            AttentionCLI.clock($0.duration), $0.presence.rawValue,
                            $0.source.rawValue, $0.domain ?? $0.appName ?? $0.media?.title ?? "",
                        ]
                    }))
        }
    }
}

struct AttentionMusicCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "music", abstract: "Summarize tracks, artists, albums and listening time.")

    @Option(help: "Window: today, yesterday, 24h, 7d, 30d, week, month or all.")
    var range = "7d"
    @Option(help: "Maximum tracks. Pass 0 for all.") var limit = 25
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let all = try AttentionCLI.summary(range: range).music
            let music = limit == 0 ? all : Array(all.prefix(limit))
            if json {
                CLIOut.json(.array(music.map(AttentionCLI.musicJSON)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["TRACK", "ARTIST", "ALBUM", "SERVICE", "TIME"],
                    rows: music.map {
                        [
                            $0.title, $0.artist ?? "", $0.album ?? "", $0.service,
                            AttentionCLI.clock($0.duration),
                        ]
                    }))
        }
    }
}

struct AttentionCategoriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "categories", abstract: "List categories or classify an entity.",
        subcommands: [AttentionCategoryListCommand.self, AttentionCategorizeCommand.self],
        defaultSubcommand: AttentionCategoryListCommand.self)
}

struct AttentionCategoryListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List categories and identity rules.", aliases: ["list"])
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        let settings = AttentionCLI.repository.loadSettings()
        if json {
            CLIOut.json(
                .object([
                    "categories": .array(
                        settings.categories.map {
                            .object([
                                "id": .string($0.id), "name": .string($0.name),
                                "kind": .string($0.kind.rawValue), "color": .string($0.color),
                            ])
                        }),
                    "rules": .array(
                        settings.rules.map {
                            .object([
                                "id": .string($0.id), "name": .string($0.name),
                                "categoryID": .string($0.categoryID),
                                "bundleIDs": .strings($0.bundleIDs),
                                "domains": .strings($0.domains),
                            ])
                        }),
                ]))
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["ID", "NAME", "KIND"],
                rows: settings.categories.map { [$0.id, $0.name, $0.kind.rawValue] }))
    }
}

struct AttentionCategorizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Assign an entity ID to a category.")
    @Argument(help: "Entity ID from attention summary, such as app:com.example.App.")
    var entity: String
    @Argument(help: "Category ID or exact category name.") var category: String
    @Option(help: "Friendly identity name for a new or existing rule.") var name: String?
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let rule = try AttentionCLI.categorize(entity: entity, category: category, name: name)
            if json {
                CLIOut.json(
                    .object([
                        "id": .string(rule.id), "name": .string(rule.name),
                        "categoryID": .string(rule.categoryID),
                        "bundleIDs": .strings(rule.bundleIDs), "domains": .strings(rule.domains),
                    ]))
            } else {
                CLIOut.out("categorized \(rule.name) as \(rule.categoryID)")
            }
        }
    }
}

struct AttentionFocusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus", abstract: "Start, inspect or finish a focus session.",
        subcommands: [
            AttentionFocusStatusCommand.self, AttentionFocusStartCommand.self,
            AttentionFocusStopCommand.self,
        ], defaultSubcommand: AttentionFocusStatusCommand.self)
}

struct AttentionFocusStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show the active focus session.")
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        let focus = AttentionCLI.repository.activeFocus()
        if json {
            CLIOut.json(
                focus.map {
                    .object([
                        "id": .string($0.id), "name": .string($0.name),
                        "startedAt": .date($0.startedAt),
                        "plannedSeconds": .double($0.plannedDuration),
                    ])
                } ?? .null)
        } else {
            CLIOut.out(
                focus.map { "\($0.name), planned \(AttentionCLI.clock($0.plannedDuration))" }
                    ?? "no focus session")
        }
    }
}

struct AttentionFocusStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start a named focus session.")
    @Option(name: .customLong("for"), help: "Planned duration such as 25m, 1h or 90m.")
    var duration = "25m"
    @Option(help: "What this session is for.") var name = "Focus"
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let focus = try AttentionCLI.repository.startFocus(
                name: name, duration: AttentionCLI.duration(duration))
            if json {
                CLIOut.json(
                    .object([
                        "id": .string(focus.id), "name": .string(focus.name),
                        "startedAt": .date(focus.startedAt),
                        "plannedSeconds": .double(focus.plannedDuration),
                    ]))
            } else {
                CLIOut.out(
                    "focus started: \(focus.name), \(AttentionCLI.clock(focus.plannedDuration))")
            }
        }
    }
}

struct AttentionFocusStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Finish the active focus session.", aliases: ["end"])
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let focus = try AttentionCLI.repository.endFocus()
            let elapsed = (focus.endedAt ?? Date()).timeIntervalSince(focus.startedAt)
            if json {
                CLIOut.json(
                    .object([
                        "id": .string(focus.id), "name": .string(focus.name),
                        "startedAt": .date(focus.startedAt), "endedAt": .date(focus.endedAt),
                        "elapsedSeconds": .double(elapsed),
                    ]))
            } else {
                CLIOut.out("focus finished: \(focus.name), \(AttentionCLI.clock(elapsed))")
            }
        }
    }
}

struct AttentionDoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check local collectors, data and browser extension files."
    )
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        let repository = AttentionCLI.repository
        let settings = repository.loadSettings()
        let browserServerReady: Bool
        if settings.isEnabled, settings.browserTrackingEnabled {
            browserServerReady = await AttentionIngestionServer.isHealthy(
                port: settings.serverPort, timeout: 0.5)
        } else {
            browserServerReady = false
        }
        let disabled = !settings.isEnabled
        let checks: [(String, Bool, String)] = [
            ("helper", AppBridge.helperIsRunning, "Edith menu bar process"),
            (
                "attention", true,
                disabled ? "disabled by master switch" : "enabled by master switch"
            ),
            (
                "application tracking", disabled || settings.trackingEnabled,
                disabled ? "disabled by master switch" : "macOS foreground collector"
            ),
            (
                "browser tracking", disabled || browserServerReady,
                disabled
                    ? "disabled by master switch"
                    : browserServerReady
                        ? "local server is accepting connections"
                        : settings.browserTrackingEnabled
                            ? "enabled but local server is unavailable"
                            : "local browser server is disabled"
            ),
            (
                "extension bundle", AttentionExtensionInstaller.bundledDirectory != nil,
                "packaged Chrome extension"
            ),
            ("event store", repository.hasEvents(), repository.directory.path),
        ]
        if json {
            CLIOut.json(
                .object([
                    "ok": .bool(checks.filter { $0.0 != "event store" }.allSatisfy(\.1)),
                    "checks": .array(
                        checks.map {
                            .object([
                                "name": .string($0.0), "ok": .bool($0.1),
                                "detail": .string($0.2),
                            ])
                        }),
                ]))
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["CHECK", "STATE", "DETAIL"],
                rows: checks.map { [$0.0, $0.1 ? "ok" : "not ready", $0.2] }))
    }
}
