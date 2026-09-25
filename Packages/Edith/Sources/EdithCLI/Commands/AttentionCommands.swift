import ArgumentParser
import EdithKit
import Foundation

struct AttentionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attention",
        abstract: "Local attention, application, website, music and focus data.",
        subcommands: [
            AttentionStatusCommand.self, AttentionSummaryCommand.self,
            AttentionBreakdownCommand.self, AttentionAgentsCommand.self,
            AttentionTimelineCommand.self, AttentionMusicCommand.self,
            AttentionCategoriesCommand.self, AttentionFocusCommand.self,
            AttentionDoctorCommand.self,
        ],
        defaultSubcommand: AttentionStatusCommand.self)
}

enum AttentionCLIEnvironment {
    nonisolated(unsafe) static var eventSink: AttentionEventSink? = AgentAttentionSink()
}

enum AttentionCLI {
    static var repository: AttentionRepository {
        AttentionRepository(eventSink: AttentionCLIEnvironment.eventSink)
    }

    static func events(from: Date, to: Date) throws -> [AttentionEvent] {
        if let sink = repository.resolvedEventSink {
            return try sink.events(from: from, to: to)
        }
        return repository.events(from: from, to: to)
    }

    static func hasEvents() throws -> Bool {
        if let sink = repository.resolvedEventSink { return try sink.hasEvents() }
        return repository.hasEvents()
    }

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
            events: try events(from: interval.start, to: interval.end),
            settings: repository.loadSettings(),
            classifications: repository.loadClassifications(), from: interval.start,
            to: interval.end)
    }

    static let dimensions: [String: String] = [
        "app": AttentionDimension.entity, "title": AttentionDimension.title,
        "url": AttentionDimension.url, "page": AttentionTag.page,
        "machine": AttentionTag.machine, "agent": AttentionTag.agent,
        "project": AttentionTag.project, "repo": AttentionTag.repository,
        "section": AttentionTag.section, "channel": AttentionTag.channel,
        "group": AttentionTag.group, "search": AttentionTag.search,
        "doc": AttentionTag.document,
    ]

    static func secondsJSON(_ values: [String: TimeInterval]) -> JSONValue {
        .object(values.mapValues { .double($0) })
    }

    static func agentTotalJSON(_ total: AttentionAgentTotal) -> JSONValue {
        .object([
            "key": .string(total.key),
            "workingSeconds": .double(total.working),
            "blockedSeconds": .double(total.blocked),
            "attendedSeconds": .double(total.attended),
            "sessions": .int(total.sessions),
        ])
    }

    static func summaryJSON(_ summary: AttentionSummary) -> JSONValue {
        .object([
            "from": .date(summary.from),
            "to": .date(summary.to),
            "activeSeconds": .double(summary.activeDuration),
            "idleSeconds": .double(summary.idleDuration),
            "productiveSeconds": .double(summary.productiveDuration),
            "distractingSeconds": .double(summary.distractingDuration),
            "unclassifiedSeconds": .double(summary.unclassifiedDuration),
            "productivePercent": .double(
                percent(summary.productiveDuration, of: summary.activeDuration)),
            "distractingPercent": .double(
                percent(summary.distractingDuration, of: summary.activeDuration)),
            "pulse": summary.pulse.map { .double($0) } ?? .null,
            "contextSwitches": .int(summary.contextSwitches),
            "productivity": .object(
                Dictionary(
                    uniqueKeysWithValues: AttentionProductivity.allCases.map {
                        ($0.identifier, JSONValue.double(summary.duration($0)))
                    })),
            "spheres": secondsJSON(summary.spheres),
            "categories": .array(
                summary.categories.map {
                    .object([
                        "id": .string($0.category.id), "name": .string($0.category.name),
                        "productivity": .string($0.category.productivity.identifier),
                        "sphere": .string($0.category.sphere.rawValue),
                        "durationSeconds": .double($0.duration),
                    ])
                }),
            "deepWorkSeconds": .double(summary.deepWorkDuration),
            "focusBlocks": .array(
                summary.focusBlocks.map {
                    .object([
                        "start": .date($0.start), "end": .date($0.end),
                        "focusedSeconds": .double($0.focused),
                        "interruptions": .int($0.interruptions), "top": .strings($0.topNames),
                    ])
                }),
            "medianStretchSeconds": .double(summary.medianStretch),
            "longestStretchSeconds": .double(summary.longestStretch),
            "transitions": .array(
                summary.transitions.map {
                    .object([
                        "from": .string($0.from), "to": .string($0.to), "count": .int($0.count),
                    ])
                }),
            "signals": .object([
                "keys": .int(summary.signals.keys), "clicks": .int(summary.signals.clicks),
                "scrolls": .int(summary.signals.scrolls),
            ]),
            "agentWorkingSeconds": .double(summary.agents.working),
            "agentBlockedSeconds": .double(summary.agents.blocked),
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
            "productivity": .string(entity.productivity.identifier),
            "sphere": .string(entity.sphere.rawValue),
            "source": .string(entity.source.rawValue),
            "durationSeconds": .double(entity.duration),
            "faviconURL": .optional(entity.faviconURL),
            "categorySource": .string(entity.categorySource.rawValue),
            "confidence": entity.confidence.map { .double($0) } ?? .null,
            "visits": .int(entity.visits),
            "categorySeconds": secondsJSON(entity.categoryDurations),
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
        if minutes == 0, seconds > 0 { return "\(seconds)s" }
        return "\(minutes)m"
    }

    static func save(settings: AttentionSettings) throws {
        try repository.saveSettings(settings)
        ConfigStore.announceChange()
    }

    static func categorize(
        entity: String, category value: String, name: String?,
        productivity: AttentionProductivity? = nil, sphere: AttentionSphere? = nil
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
        guard
            let rule = settings.assign(
                entityID: entity, categoryID: category.id, name: name, productivity: productivity,
                sphere: sphere)
        else {
            throw CLIFailure.usage(
                "\(entity) is not an entity ID",
                hint: "use an id from `ed attention summary --json`")
        }
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
            let events = try AttentionCLI.events(
                from: Date().addingTimeInterval(-86_400), to: Date())
            let browserServerReady: Bool
            if settings.isEnabled, settings.browserTrackingEnabled {
                browserServerReady = await AttentionIngestionServer.isHealthy(
                    port: settings.serverPort, timeout: 0.5)
            } else {
                browserServerReady = false
            }
            let delivery: AttentionDeliveryHealth?
            if repository.resolvedEventSink is AgentAttentionSink {
                delivery = try? await AttentionDeliveryClient.health()
            } else {
                delivery = try? await AttentionDeliverySpool(
                    file: repository.directory.appendingPathComponent("delivery-spool.json")
                ).health()
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
                        "delivery": delivery.map { value in
                            .object([
                                "pendingEvents": .int(value.pendingEvents),
                                "committedSequence": .int(Int(value.committedSequence)),
                                "rejectedEvents": .int(Int(value.rejectedEvents)),
                                "rejectedSeconds": .double(value.rejectedDuration),
                                "degraded": .bool(
                                    value.lastFailure != nil || value.rejectedEvents > 0),
                                "error": .optional(value.lastFailure),
                            ])
                        } ?? .null,
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
            if let delivery {
                CLIOut.out(
                    "delivery: \(delivery.pendingEvents) pending, \(delivery.rejectedEvents) not retained"
                )
                if let failure = delivery.lastFailure { CLIOut.out(failure) }
            } else {
                CLIOut.out("delivery: status unavailable")
            }
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
                "productive: \(AttentionCLI.clock(summary.productiveDuration)) (\(Int(AttentionCLI.percent(summary.productiveDuration, of: summary.activeDuration).rounded()))%)"
            )
            CLIOut.out(
                "distracting: \(AttentionCLI.clock(summary.distractingDuration)) (\(Int(AttentionCLI.percent(summary.distractingDuration, of: summary.activeDuration).rounded()))%)"
            )
            if let pulse = summary.pulse {
                CLIOut.out("pulse: \(Int(pulse.rounded()))/100")
            }
            CLIOut.out(
                "work: \(AttentionCLI.clock(summary.duration(AttentionSphere.work))), personal: \(AttentionCLI.clock(summary.duration(AttentionSphere.personal)))"
            )
            CLIOut.out("idle: \(AttentionCLI.clock(summary.idleDuration))")
            CLIOut.out(
                "deep work: \(AttentionCLI.clock(summary.deepWorkDuration)) in \(summary.focusBlocks.count) blocks"
            )
            CLIOut.out(
                "context switches: \(summary.contextSwitches), median stretch \(AttentionCLI.clock(summary.medianStretch))"
            )
            if !summary.agents.isEmpty {
                CLIOut.out(
                    "agents: \(AttentionCLI.clock(summary.agents.working)) working, \(AttentionCLI.clock(summary.agents.blocked)) waiting"
                )
            }
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

struct AttentionBreakdownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breakdown",
        abstract: "Group active time by app, title, URL, machine, agent, project and more.")

    @Option(
        name: .customLong("by"),
        help:
            "app, title, url, page, machine, agent, project, repo, section, channel, group, search or doc."
    )
    var by = "app"
    @Option(help: "Window: today, yesterday, 24h, 7d, 30d, week, month or all.")
    var range = "today"
    @Option(help: "Maximum rows. Pass 0 for all.") var limit = 25
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            guard let key = AttentionCLI.dimensions[by.lowercased()] else {
                throw CLIFailure.usage(
                    "\(by) is not a breakdown",
                    hint:
                        "use one of \(AttentionCLI.dimensions.keys.sorted().joined(separator: ", "))"
                )
            }
            let summary = try AttentionCLI.summary(range: range)
            let settings = AttentionCLI.repository.loadSettings()
            let dimension = summary.dimension(key)
            let all = dimension?.rows ?? []
            let rows = limit == 0 ? all : Array(all.prefix(limit))
            if json {
                CLIOut.json(
                    .object([
                        "by": .string(by.lowercased()),
                        "totalSeconds": .double(dimension?.total ?? 0),
                        "rows": .array(
                            rows.map {
                                .object([
                                    "key": .string($0.key),
                                    "durationSeconds": .double($0.duration),
                                    "categorySeconds": AttentionCLI.secondsJSON($0.categories),
                                    "interactions": .int($0.interactions),
                                    "entities": .strings($0.entityNames),
                                ])
                            }),
                    ]))
                return
            }
            let total = dimension?.total ?? 0
            CLIOut.out(
                TextTable.render(
                    headers: [by.uppercased(), "TIME", "SHARE", "CATEGORY"],
                    rows: rows.map { row in
                        let top = row.categories.max { $0.value < $1.value }?.key
                        return [
                            row.key, AttentionCLI.clock(row.duration),
                            "\(Int(AttentionCLI.percent(row.duration, of: total).rounded()))%",
                            top.map { settings.category($0).name } ?? "",
                        ]
                    }))
        }
    }
}

struct AttentionAgentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "Agent working and waiting time by machine, agent and project.")

    @Option(help: "Window: today, yesterday, 24h, 7d, 30d, week, month or all.")
    var range = "today"
    @Option(help: "Maximum sessions. Pass 0 for all.") var limit = 20
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let agents = try AttentionCLI.summary(range: range).agents
            let sessions = limit == 0 ? agents.sessions : Array(agents.sessions.prefix(limit))
            if json {
                CLIOut.json(
                    .object([
                        "workingSeconds": .double(agents.working),
                        "blockedSeconds": .double(agents.blocked),
                        "attendedSeconds": .double(agents.attended),
                        "peakConcurrent": .int(agents.peakConcurrent),
                        "machines": .array(agents.machines.map(AttentionCLI.agentTotalJSON)),
                        "agents": .array(agents.kinds.map(AttentionCLI.agentTotalJSON)),
                        "projects": .array(agents.projects.map(AttentionCLI.agentTotalJSON)),
                        "sessions": .array(
                            sessions.map {
                                .object([
                                    "id": .string($0.id), "title": .string($0.title),
                                    "machine": .string($0.machine), "agent": .string($0.kind),
                                    "project": .optional($0.project),
                                    "workingSeconds": .double($0.working),
                                    "blockedSeconds": .double($0.blocked),
                                    "lastSeen": .date($0.lastSeen),
                                ])
                            }),
                    ]))
                return
            }
            CLIOut.out(
                "working: \(AttentionCLI.clock(agents.working)), waiting: \(AttentionCLI.clock(agents.blocked)), watched: \(AttentionCLI.clock(agents.attended)), peak: \(agents.peakConcurrent)"
            )
            for (title, totals) in [
                ("MACHINE", agents.machines), ("AGENT", agents.kinds), ("PROJECT", agents.projects),
            ] where !totals.isEmpty {
                CLIOut.out("")
                CLIOut.out(
                    TextTable.render(
                        headers: [title, "WORKING", "WAITING", "WATCHED", "SESSIONS"],
                        rows: totals.map {
                            [
                                $0.key, AttentionCLI.clock($0.working),
                                AttentionCLI.clock($0.blocked), AttentionCLI.clock($0.attended),
                                String($0.sessions),
                            ]
                        }))
            }
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
            let all = try AttentionCLI.events(from: interval.start, to: interval.end)
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
        subcommands: [
            AttentionCategoryListCommand.self, AttentionCategorizeCommand.self,
            AttentionAutoCategorizeCommand.self,
        ],
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
                                "productivity": .string($0.productivity.identifier),
                                "sphere": .string($0.sphere.rawValue),
                            ])
                        }),
                    "rules": .array(
                        settings.rules.map {
                            .object([
                                "id": .string($0.id), "name": .string($0.name),
                                "categoryID": .string($0.categoryID),
                                "bundleIDs": .strings($0.bundleIDs),
                                "domains": .strings($0.domains),
                                "productivity": $0.productivity.map { .string($0.identifier) }
                                    ?? .null,
                                "sphere": $0.sphere.map { .string($0.rawValue) } ?? .null,
                            ])
                        }),
                ]))
            return
        }
        CLIOut.out(
            TextTable.render(
                headers: ["ID", "NAME", "PRODUCTIVITY", "SPHERE"],
                rows: settings.categories.map {
                    [$0.id, $0.name, $0.productivity.identifier, $0.sphere.rawValue]
                }))
    }
}

struct AttentionAutoCategorizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Ask Jev to categorize unclassified apps, sites and titles now.")
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let report = try await AttentionBackgroundClient.categorize()
            if json {
                CLIOut.json(
                    .object([
                        "available": .bool(report.available),
                        "entities": .int(report.entities), "titles": .int(report.titles),
                    ]))
                return
            }
            guard report.available else {
                throw CLIFailure.unavailable(
                    "Jev categorization is off or no Jev key is configured",
                    hint: "save a key with `ed jev key set` and turn on Jev in Attention settings")
            }
            CLIOut.out(
                "Jev categorized \(report.entities) apps and sites and \(report.titles) titles")
        }
    }
}

struct AttentionCategorizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Assign an entity ID to a category.")
    @Argument(help: "Entity ID from attention summary, such as app:com.example.App.")
    var entity: String
    @Argument(help: "Category ID or exact category name.") var category: String
    @Option(help: "Friendly identity name for a new or existing rule.") var name: String?
    @Option(
        help:
            "Override productivity: very_productive, productive, neutral, distracting or very_distracting."
    )
    var productivity: String?
    @Option(help: "Override the sphere: work, personal or both.") var sphere: String?
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            let level = try productivity.map { raw in
                guard let level = AttentionProductivity(identifier: raw.lowercased()) else {
                    throw CLIFailure.usage(
                        "\(raw) is not a productivity level",
                        hint:
                            "use very_productive, productive, neutral, distracting or very_distracting"
                    )
                }
                return level
            }
            let area = try sphere.map { raw in
                guard let area = AttentionSphere(rawValue: raw.lowercased()) else {
                    throw CLIFailure.usage(
                        "\(raw) is not a sphere", hint: "use work, personal or both")
                }
                return area
            }
            let rule = try AttentionCLI.categorize(
                entity: entity, category: category, name: name, productivity: level, sphere: area)
            if json {
                CLIOut.json(
                    .object([
                        "id": .string(rule.id), "name": .string(rule.name),
                        "categoryID": .string(rule.categoryID),
                        "bundleIDs": .strings(rule.bundleIDs), "domains": .strings(rule.domains),
                        "productivity": rule.productivity.map { .string($0.identifier) } ?? .null,
                        "sphere": rule.sphere.map { .string($0.rawValue) } ?? .null,
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
            let focus = try AttentionFocusOperationExecution.start(
                name: name, duration: AttentionCLI.duration(duration),
                repository: AttentionCLI.repository)
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
            let focus = try AttentionFocusOperationExecution.stop(
                repository: AttentionCLI.repository)
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
        let storeCheck: (String, Bool, String)
        do {
            let present = try AttentionCLI.hasEvents()
            storeCheck = (
                "event store", true, present ? "recorded events available" : "ready, no events yet"
            )
        } catch {
            storeCheck = ("event store", false, error.localizedDescription)
        }
        let checks: [(String, Bool, String)] = [
            (
                "agent", (try? CLIEnvironment.verifyAgentHandshake()) != nil,
                "Edith background agent"
            ),
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
            storeCheck,
        ]
        if json {
            CLIOut.json(
                .object([
                    "ok": .bool(checks.allSatisfy(\.1)),
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
