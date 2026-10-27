import Foundation

enum UsageNativeAssembly {
    static let labels = [
        "cli": "Claude Code", "cowork": "Cowork", "codex": "Codex", "codex-cloud": "Codex Cloud",
        "claude-cloud": "Claude Code Web", "cursor": "Cursor", "opencode": "OpenCode",
        "commandcode": "Command Code", "amp": "Amp", "droid": "Droid", "codebuff": "Codebuff",
        "hermes": "Hermes", "pi": "pi-agent", "goose": "Goose", "kilo": "Kilo", "gemini": "Gemini",
        "copilot": "GitHub Copilot", "kimi": "Kimi", "qwen": "Qwen", "openclaw": "OpenClaw",
        "grok": "Grok",
    ]

    static func deduplicate(_ events: [UsageNativeEvent]) -> [UsageNativeEvent] {
        var unique: [String: UsageNativeEvent] = [:]
        let copilot = events.filter { $0.source == "copilot" && $0.observationPriority != nil }
        func overshadowed(_ event: UsageNativeEvent) -> Bool {
            guard event.source == "copilot", let priority = event.observationPriority else {
                return false
            }
            return copilot.contains { candidate in
                guard let other = candidate.observationPriority, other < priority else {
                    return false
                }
                if priority == 4 { return candidate.session == event.session }
                return (event.traceID != nil && candidate.traceID == event.traceID)
                    || (event.receiptID != nil && candidate.receiptID == event.receiptID)
            }
        }
        let localReceipts = Set(
            events.filter { $0.source == "cli" || $0.source == "cowork" }.compactMap(\.receiptID))
        for event in events {
            if overshadowed(event) { continue }
            if event.source == "claude-cloud", let receipt = event.receiptID,
                localReceipts.contains(receipt)
            {
                continue
            }
            let key = event.source + "\u{0}" + (event.identity ?? UUID().uuidString)
            if let prior = unique[key],
                prior.tokens.output > event.tokens.output
                    || (prior.tokens.output == event.tokens.output
                        && prior.tokens.total >= event.tokens.total)
            {
                continue
            }
            unique[key] = event
        }
        return unique.values.sorted {
            ($0.timestamp, $0.source, $0.identity ?? "") < (
                $1.timestamp, $1.source, $1.identity ?? ""
            )
        }
    }

    static func document(
        archive: UsageNativeArchive, now: Date,
        timezone: TimeZone, cloudSources: [String], accounts: UsageNativeAccounts = .init()
    ) throws -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let formatter = DateFormatter(); formatter.calendar = calendar;
        formatter.timeZone = timezone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var projects: [String: UsageNativeProject] = [:]
        var aggregate = UsageNativeAggregate()
        var estimator = UsageNativePricing.Estimator()
        try archive.forEachEffectiveEvent { raw, sequence in
            var event = raw
            if event.identity == nil { event.identity = "anon:" + String(sequence) }
            event.source = accounts.source(of: event)
            guard event.timestamp.timeIntervalSince1970.isFinite, event.tokens.total.isFinite else {
                throw UsageNativeFailure.invalidInput("usage receipt")
            }
            let project: UsageNativeProject
            if let cached = projects[event.cwd] {
                project = cached
            } else {
                project = try UsageNativeProjects.resolve(event.cwd, archive: archive)
                projects[event.cwd] = project
            }
            let estimate = estimator.estimate(event)
            guard estimate.cost.isFinite else { throw UsageNativeFailure.invalidInput("price") }
            aggregate.add(
                event, cost: estimate.cost, missing: estimate.missing, fallback: estimate.fallback,
                project: project,
                period: event.reportingDay ?? formatter.string(from: event.timestamp),
                hour: calendar.component(.hour, from: event.timestamp))
        }
        let daily = aggregate.dailyBlocks()
        let sourceOrder = [
            "cli", "cowork", "codex", "codex-cloud", "claude-cloud", "cursor", "opencode",
        ]
        let sourceSet = aggregate.sources
        let sources =
            sourceOrder.filter(sourceSet.contains) + sourceSet.subtracting(sourceOrder).sorted()
        let stamp = ISO8601DateFormatter().string(from: now)
        return [
            "schemaVersion": 8, "generatedAt": stamp, "sources": sources, "defaultSources": sources,
            "sourceMeta": Dictionary(
                uniqueKeysWithValues: sources.map { source in
                    let account = accounts.label(source)
                    return (
                        source,
                        [
                            "label": account ?? labels[source] ?? source,
                            "tool": account == nil ? source : "cli",
                        ]
                    )
                }),
            "totals": aggregate.totals(), "daily": daily, "sessions": aggregate.sessionNodes(),
            "cloudSourcesCollected": cloudSources.sorted(),
            "historyRetention": try archive.reconcile(daily),
            "pricing": [
                "revision": UsageNativePricingSnapshot.revision,
                "source": UsageNativePricingSnapshot.source,
                "license": UsageNativePricingSnapshot.license,
                "unpricedModels": aggregate.unpricedModels.sorted(),
            ],
        ]
    }
}
