import Foundation

struct UsageNativeCostedEvent {
    let event: UsageNativeEvent
    let cost: Double
    let missing: Bool
    let fallback: Bool
    let project: UsageNativeProject
    let period: String
    let hour: Int
}

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
        let localReceipts = Set(
            events.filter { $0.source == "cli" || $0.source == "cowork" }.compactMap(\.receiptID))
        for event in events {
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
        events: [UsageNativeEvent], archive: UsageNativeArchive, now: Date,
        timezone: TimeZone, cloudSources: [String]
    ) throws -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let formatter = DateFormatter(); formatter.calendar = calendar;
        formatter.timeZone = timezone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var projects: [String: UsageNativeProject] = [:]
        var values: [UsageNativeCostedEvent] = []
        for event in deduplicate(events) {
            try Task.checkCancellation()
            guard event.timestamp.timeIntervalSince1970.isFinite, event.tokens.total.isFinite else {
                throw UsageNativeFailure.invalidInput("usage receipt")
            }
            let project: UsageNativeProject
            if let cached = projects[event.cwd] {
                project = cached
            } else {
                project = try UsageNativeProjects.resolve(event.cwd, archive: archive);
                projects[event.cwd] = project
            }
            let estimate = UsageNativePricing.estimate(event)
            guard estimate.cost.isFinite else { throw UsageNativeFailure.invalidInput("price") }
            values.append(
                .init(
                    event: event, cost: estimate.cost, missing: estimate.missing,
                    fallback: estimate.fallback,
                    project: project, period: event.reportingDay ?? formatter.string(from: event.timestamp),
                    hour: calendar.component(.hour, from: event.timestamp)))
        }
        let days = Dictionary(grouping: values, by: \.period)
        var daily: [[String: Any]] = []
        for period in days.keys.sorted() {
            try Task.checkCancellation()
            let day = days[period]!
            let detail = day.filter { $0.event.detailAvailable }
            var block: [String: Any] = ["period": period, "bySource": dailySources(day)]
            block["hours"] = (0..<24).map { hour -> [String: Any] in
                let records = detail.filter { $0.hour == hour }
                var node = detailNode(records)
                node["byPath"] = Dictionary(grouping: records, by: { $0.event.cwd }).mapValues(
                    detailNode)
                return node
            }
            block["projects"] = projectNodes(detail)
            daily.append(block)
        }
        let sourceOrder = [
            "cli", "cowork", "codex", "codex-cloud", "claude-cloud", "cursor", "opencode",
        ]
        let sourceSet = Set(values.map { $0.event.source })
        let sources =
            sourceOrder.filter(sourceSet.contains) + sourceSet.subtracting(sourceOrder).sorted()
        let totals = totals(values)
        let stamp = ISO8601DateFormatter().string(from: now)
        let sessionGroups = Dictionary(
            grouping: values.filter { !$0.event.session.isEmpty && $0.event.detailAvailable },
            by: { $0.event.source + "\u{0}" + $0.event.session }
        )
        let sessions: [[String: Any]] = sessionGroups.values.map { records -> [String: Any] in
            [
                "id": records[0].event.session, "source": records[0].event.source,
                "cost": records.reduce(0) { $0 + $1.cost },
                "tokens": records.reduce(0) { $0 + $1.event.tokens.total },
                "lastActivity": ISO8601DateFormatter().string(
                    from: records.map { $0.event.timestamp }.max()!),
            ]
        }.sorted {
            ($0["source"] as! String, $0["id"] as! String) < (
                $1["source"] as! String, $1["id"] as! String
            )
        }
        return [
            "schemaVersion": 8, "generatedAt": stamp, "sources": sources, "defaultSources": sources,
            "sourceMeta": Dictionary(
                uniqueKeysWithValues: sources.map { ($0, ["label": labels[$0] ?? $0, "tool": $0]) }),
            "totals": totals, "daily": daily, "sessions": sessions,
            "cloudSourcesCollected": cloudSources.sorted(),
            "historyRetention": try archive.reconcile(daily),
            "pricing": [
                "revision": UsageNativePricingSnapshot.revision,
                "source": UsageNativePricingSnapshot.source,
                "license": UsageNativePricingSnapshot.license,
                "unpricedModels": Array(Set(values.filter(\.missing).map { $0.event.model }))
                    .sorted(),
            ],
        ]
    }

    private static func totals(_ records: [UsageNativeCostedEvent]) -> [String: Any] {
        var tokens = UsageNativeTokens()
        var cost = 0.0
        for row in records {
            tokens.input += row.event.tokens.input; tokens.output += row.event.tokens.output
            tokens.creation += row.event.tokens.creation; tokens.read += row.event.tokens.read;
            cost += row.cost
        }
        return [
            "tokens": tokens.total, "cost": cost, "inputTokens": tokens.input,
            "outputTokens": tokens.output,
            "cacheCreationTokens": tokens.creation, "cacheReadTokens": tokens.read,
            "bySource": Dictionary(grouping: records, by: { $0.event.source }).mapValues { rows in
                [
                    "tokens": rows.reduce(0.0) { $0 + $1.event.tokens.total },
                    "cost": rows.reduce(0.0) { $0 + $1.cost },
                ]
            },
        ]
    }

    private static func dailySources(_ records: [UsageNativeCostedEvent]) -> [String: [[String:
        Any]]]
    {
        Dictionary(grouping: records, by: { $0.event.source }).mapValues { rows in
            let models = Dictionary(grouping: rows, by: { $0.event.model })
            return models.keys.sorted().map { model in
                let rows = models[model]!
                var row = totals(rows); row.removeValue(forKey: "bySource");
                row["modelName"] = model
                row["costMissing"] = rows.contains(where: \.missing)
                row["unpricedTokens"] = rows.filter(\.missing).reduce(0.0) {
                    $0 + $1.event.tokens.total
                }
                row["isFallback"] = rows.contains(where: \.fallback)
                return row
            }
        }
    }

    private static func detailSources(_ records: [UsageNativeCostedEvent]) -> [String: [String:
        Any]]
    {
        Dictionary(grouping: records, by: { $0.event.source }).mapValues { rows in
            [
                "tokens": rows.reduce(0.0) { $0 + $1.event.tokens.total },
                "cost": rows.reduce(0.0) { $0 + $1.cost },
                "byModel": Dictionary(grouping: rows, by: { $0.event.model }).mapValues { models in
                    [
                        "tokens": models.reduce(0.0) { $0 + $1.event.tokens.total },
                        "cost": models.reduce(0.0) { $0 + $1.cost },
                    ]
                },
            ]
        }
    }

    private static func detailNode(_ records: [UsageNativeCostedEvent]) -> [String: Any] {
        [
            "tokens": records.reduce(0.0) { $0 + $1.event.tokens.total },
            "cost": records.reduce(0.0) { $0 + $1.cost }, "bySource": detailSources(records),
        ]
    }

    private static func projectNodes(_ records: [UsageNativeCostedEvent]) -> [[String: Any]] {
        let grouped = Dictionary(
            grouping: records, by: { $0.project.repositoryID + "\u{0}" + $0.project.root })
        return grouped.values.map { rows in
            let project = rows[0].project
            var node = detailNode(rows)
            node["projectName"] = project.repositoryName;
            node["repositoryID"] = project.repositoryID
            node["repositoryName"] = project.repositoryName;
            node["repositoryURL"] = project.repositoryURL ?? ""
            node["folderName"] = project.folderName; node["path"] = project.root
            node["attribution"] = [
                "method": project.root.isEmpty ? "unattributed" : "working-directory"
            ]
            node["chats"] = chatNodes(rows.filter { $0.project.worktree == nil })
            node["worktrees"] = Dictionary(
                grouping: rows.filter { $0.project.worktree != nil }, by: { $0.project.worktree! }
            ).map { name, records -> [String: Any] in
                [
                    "name": name, "tokens": records.reduce(0.0) { $0 + $1.event.tokens.total },
                    "cost": records.reduce(0.0) { $0 + $1.cost }, "chats": chatNodes(records),
                ]
            }.sorted { ($0["tokens"] as! Double) > ($1["tokens"] as! Double) }
            return node
        }.sorted {
            ($0["tokens"] as! Double, $0["repositoryName"] as! String) > (
                $1["tokens"] as! Double, $1["repositoryName"] as! String
            )
        }
    }

    private static func chatNodes(_ rows: [UsageNativeCostedEvent]) -> [[String: Any]] {
        Dictionary(grouping: rows, by: { $0.event.source + "\u{0}" + $0.event.session }).values.map
        { records in
            let first = records[0].event
            let title =
                records.compactMap { $0.event.title }.last
                ?? (first.session.isEmpty ? "Untitled chat" : "Chat " + first.session.prefix(8))
            return [
                "id": first.session, "path": first.cwd, "title": title, "source": first.source,
                "tokens": records.reduce(0.0) { $0 + $1.event.tokens.total },
                "cost": records.reduce(0.0) { $0 + $1.cost },
                "firstTs": records.map { $0.event.timestamp.timeIntervalSince1970 * 1000 }.min()
                    ?? 0,
                "lastTs": records.map { $0.event.timestamp.timeIntervalSince1970 * 1000 }.max()
                    ?? 0,
            ] as [String: Any]
        }.sorted {
            ($0["tokens"] as! Double, $0["id"] as! String) > (
                $1["tokens"] as! Double, $1["id"] as! String
            )
        }
    }
}
