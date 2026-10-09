import EdithDatabase
import Foundation

public enum SurfaceSampleData {
    public static let date = Date(timeIntervalSince1970: 1_791_547_200)

    public static func agents() -> AgentActivitySnapshot {
        let states: [(AgentActivityProvider, AgentActivityPhase, String, String)] = [
            (.claude, .working, "Atlas", "Read"),
            (.codex, .working, "Beacon", "Shell"),
            (.opencode, .waiting, "Atlas", "Question"),
            (.claude, .stuck, "Harbor", "Build"),
        ]
        let sessions = states.enumerated().map { index, item in
            var event = AgentActivityEvent(
                provider: item.0, sessionID: "sample-\(index)", eventName: "PreToolUse",
                phase: item.1, project: "/sample/" + item.2,
                receivedAt: date.addingTimeInterval(-Double(index + 1) * 60))
            event.tool = item.3
            event.detail = "Sample workspace activity"
            return AgentActivitySession(event: event)
        }
        let providers = Dictionary(
            uniqueKeysWithValues: AgentActivityProvider.allCases.map {
                ($0.rawValue, AgentActivityProviderSettings(observing: true))
            })
        return .init(
            sessions: sessions, refreshedAt: date,
            settings: .init(providers: providers, monitorTerminalAttention: true))
    }

    public static func snapshot(_ tile: SurfaceTile) -> SurfaceExtensionSnapshot {
        var value: SurfaceExtensionSnapshot
        if tile.widget == .limits { return limits(tile) }
        if tile.widget == .codeStats { return codeStats(tile) }
        if tile.widget == .github || tile.widget == .ability("quinjet") {
            value = github(tile)
        } else if tile.widget == .databases {
            value = databases(tile)
        } else if tile.widget == .ability("audioMixer") || tile.widget == .ability("timeLapse") {
            value = media(tile)
        } else if tile.widget == .ability("companion") {
            return memory(tile)
        } else {
            value = base(tile.widget)
        }
        value.updatedAt = date
        let sources = tile.widget.sourceChoices
        if !sources.isEmpty {
            value.sources = sources
            for index in value.rows.indices {
                let row = value.rows[index]
                value.rows[index] = .init(
                    row.id, source: sources[index % sources.count].id, title: row.title,
                    detail: row.detail, value: row.value, icon: row.icon,
                    progress: row.progress, actions: row.actions, volume: row.volume)
            }
        }
        if let selected = tile.sourceIDs {
            value.rows.removeAll { !selected.contains($0.sourceID) }
            if selected.isEmpty { value.metrics = [] }
        }
        if tile.sourceIDs != nil, value.rows.isEmpty {
            value.message = "No sample items match these sources."
        }
        return value
    }

    public static func limits(_ tile: SurfaceTile) -> SurfaceExtensionSnapshot {
        SurfaceCoreProjection.limits(
            .init(
                refreshedAt: date,
                providers: [
                    .init(
                        provider: .claude,
                        session: .init(percent: 63, resetsAt: date.addingTimeInterval(8040)),
                        week: .init(percent: 34, resetsAt: date.addingTimeInterval(172800))),
                    .init(
                        provider: .codex,
                        session: .init(percent: 18, resetsAt: date.addingTimeInterval(3600)),
                        week: .init(percent: 52, resetsAt: date.addingTimeInterval(259200))),
                ], failure: nil), tile: tile, now: date)
    }
    public static func codeStats(_ tile: SurfaceTile) -> SurfaceExtensionSnapshot {
        guard tile.sourceIDs?.isEmpty != true else {
            return .init(message: "Select repositories to show their code stats.")
        }
        let commits = (0..<24).map { index in
            CodeStatsCommit(
                sha: "sample-\(index)", day: index < 12 ? "2026-10-09" : "2026-10-08", hour: 9,
                repository: index.isMultiple(of: 3) ? "sample/beacon" : "sample/atlas",
                languages: ["Swift": .init(added: 100 + index, updated: 20, deleted: 5)])
        }
        var calendar = Calendar(identifier: .gregorian);
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let report = CodeStatsReportBuilder.build(
            table: CodeStatsFactBuilder.build(commits: commits),
            filter: .init(repositories: tile.sourceIDs ?? []),
            range: .days(tile.days), today: date, calendar: calendar)
        return SurfaceCoreProjection.codeStats(report, tile: tile)
    }

    private static func media(_ tile: SurfaceTile) -> SurfaceExtensionSnapshot {
        if tile.widget == .ability("audioMixer") {
            return SurfaceMediaProjection.audio(
                .init(
                    apps: [
                        .init(
                            objectID: 41, pid: 700, bundleID: "sample.music", name: "Music",
                            volume: 0.65),
                        .init(
                            objectID: 42, pid: 701, bundleID: "sample.browser", name: "Browser",
                            volume: 0),
                    ], changed: false), tile: tile, now: date)
        }
        var status = SurfaceRecorderSnapshot()
        status.sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")
        status.recording = true; status.startedAt = date.addingTimeInterval(-320)
        status.frames = 9600; status.bytes = 240_000_000; status.playbackSeconds = 320
        status.sources = 1; status.systemAudio = true
        return SurfaceMediaProjection.recorder(
            status, library: .init(), tile: tile, now: date)
    }

    private static func memory(_ tile: SurfaceTile) -> SurfaceExtensionSnapshot {
        SurfaceMemoryProjection.snapshot(
            .init(
                checkedAt: date, endpoint: "", reachable: true, degraded: false,
                checks: [.init(name: "Search index", ok: true, detail: "Ready for local search")],
                failure: nil, skipped: false),
            status: .init(
                sources: 8, episodes: 240, claims: 96, observations: 180,
                chunks: 720, pendingEpisodes: 2, latestIngestedAt: nil),
            episodes: [
                .init(
                    id: "sample-note", occurredAt: "2026-10-09T09:00:00Z", kind: "note",
                    title: "Design review notes", sha256: ""),
                .init(
                    id: "sample-voice", occurredAt: "2026-10-09T08:00:00Z", kind: "voice",
                    title: "Morning ideas", sha256: ""),
                .init(
                    id: "sample-document", occurredAt: "2026-10-08T12:00:00Z", kind: "pdf",
                    title: "Sample project brief", sha256: ""),
            ], tile: tile)
    }

    private static func base(_ widget: SurfaceWidget) -> SurfaceExtensionSnapshot {
        switch widget {
        case .machines:
            return .init(
                metrics: [
                    .init("online", "Reachable", "2"), .init("offline", "Unreachable", "1"),
                    .init("total", "Registered", "3"),
                ],
                rows: [
                    .init(
                        "studio", title: "Studio Mac", detail: "macOS · Local", value: "Reachable",
                        icon: "desktopcomputer"),
                    .init(
                        "builder", title: "Build server", detail: "Linux · Remote",
                        value: "Reachable", icon: "server.rack"),
                    .init(
                        "laptop", title: "Travel laptop", detail: "macOS · Remote",
                        value: "Unreachable", icon: "laptopcomputer"),
                ])
        case .desk, .ability("clipboard"), .ability("colorPicker"):
            return .init(
                metrics: [.init("total", "Recent items", "12"), .init("pinned", "Pinned", "2")],
                rows: [
                    .init(
                        "text", title: "Design review notes", detail: "Notes · 240 bytes",
                        value: "Pinned", icon: "doc.text"),
                    .init("color", title: "#D77958", detail: "Color · 7 bytes", icon: "eyedropper"),
                    .init(
                        "image", title: "Canvas sketch.png", detail: "Image · 128 KB", icon: "photo"
                    ),
                ])
        case .media, .ability("downloads"):
            return .init(
                metrics: [
                    .init("running", "Downloading", "1"), .init("queued", "Queued", "2"),
                    .init("failed", "Needs retry", "1"), .init("finished", "Completed", "8"),
                ],
                rows: [
                    .init(
                        "active", title: "Sample landscape.mov", detail: "128 MB of 240 MB",
                        value: "Downloading", icon: "arrow.down.circle", progress: 0.53),
                    .init(
                        "failed", title: "Reference clip.mp4", detail: "Connection interrupted",
                        value: "Error", icon: "exclamationmark.circle"),
                    .init(
                        "queued", title: "Ambient loop.m4a", detail: "Waiting for a download slot",
                        value: "Queued", icon: "music.note"),
                ])
        case .ability("systemStats"):
            return .init(metrics: [
                .init("cpu", "CPU", "24%", fraction: 0.24),
                .init("memory", "Memory used", "58%", fraction: 0.58),
                .init("disk", "Storage free", "320 GB", fraction: 0.38),
            ])
        case .ability("audioMixer"), .ability("timeLapse"):
            return media(SurfaceTile(widget))
        case .ability("attention"):
            return .init(
                metrics: [
                    .init("active", "Active time", "4h 20m"),
                    .init("focus", "Focused time", "2h 15m"),
                    .init("switches", "App switches", "42"),
                    .init("agents", "Agent time", "1h 10m"),
                ],
                rows: [
                    .init(
                        "editor", title: "Editor", detail: "Development", value: "2h 10m",
                        icon: "curlybraces"),
                    .init(
                        "browser", title: "Browser", detail: "Research", value: "48m", icon: "globe"
                    ),
                ])
        case .ability("appMaintenance"):
            return .init(
                metrics: [
                    .init("updates", "Available updates", "2"),
                    .init("installed", "Installed apps", "24"),
                ],
                rows: [
                    .init(
                        "editor", title: "Sample Editor", detail: "1.4 → 1.5",
                        value: "Update available", icon: "app"),
                    .init(
                        "player", title: "Sample Player", detail: "3.0 → 3.1",
                        value: "Update available", icon: "play.rectangle"),
                ])
        case .ability("homebrew"):
            return .init(
                metrics: [
                    .init("packages", "Installed packages", "36"),
                    .init("updates", "Outdated", "2"),
                ],
                rows: [
                    .init(
                        "git", title: "git", detail: "2.52.0 → 2.53.0", value: "Update available",
                        icon: "cube.box"),
                    .init("jq", title: "jq", detail: "1.8.1", value: "Formula", icon: "cube.box"),
                ])
        case .ability("cleaner"), .ability("blitztree"):
            return .init(
                metrics: [
                    .init("space", "Reclaimable", "4.8 GB"), .init("categories", "Categories", "6"),
                ], actions: [review(widget)])
        case .ability("companion"):
            return memory(SurfaceTile(widget))
        case .ability("seoAudit"):
            return .init(
                metrics: [
                    .init("projects", "Projects", "2"), .init("pages", "Audited pages", "48"),
                    .init("issues", "Issues", "3"),
                ],
                rows: [
                    .init(
                        "atlas", title: "Atlas website", detail: "24 audited pages · 2 issues",
                        value: "92/100", icon: "globe")
                ])
        case .ability("latex"):
            return .init(
                metrics: [
                    .init("projects", "Documents", "3"), .init("reviews", "Pull requests", "1"),
                ],
                rows: [
                    .init(
                        "paper", title: "Sample research paper", detail: "sample/paper",
                        value: "PR #12", icon: "doc.richtext")
                ])
        case .ability("studio"), .ability("notchShelf"):
            return .init(
                metrics: [.init("files", "Files", "3")],
                rows: [
                    .init("video", title: "Sample demo.mov", detail: "Video · 24 MB", icon: "film"),
                    .init(
                        "image", title: "Sample storyboard.png", detail: "Image · 320 KB",
                        icon: "photo"),
                ])
        case .ability("bifrost"), .ability("system"):
            return .init(
                metrics: [
                    .init(
                        "apps", widget == .ability("system") ? "Running apps" : "Indexed apps", "8")
                ],
                rows: [
                    .init("editor", title: "Sample Editor", value: "Active", icon: "app"),
                    .init("notes", title: "Sample Notes", icon: "note.text"),
                ])
        case .ability("plugins"):
            return .init(
                metrics: [
                    .init("agents", "Detected agents", "3"),
                    .init("skills", "Available skills", "8"),
                ],
                rows: [
                    .init("claude", title: "Claude Code", icon: "terminal"),
                    .init("codex", title: "Codex", icon: "terminal"),
                ], actions: [review(widget)])
        case .ability("virtualCamera"):
            return .init(
                metrics: [.init("scenes", "Saved scenes", "3")],
                rows: [
                    .init("desk", title: "Desk view", value: "Selected", icon: "web.camera"),
                    .init("presentation", title: "Presentation", icon: "rectangle.on.rectangle"),
                ], message: "Open Camera to preview, frame, or start the camera.")
        case .ability("keepAwake"), .ability("focusDim"), .ability("keystrokeHighlight"),
            .ability("windowSweaters"), .ability("presenter"), .ability("lidAwake"),
            .ability("micMute"):
            return .init(
                metrics: [.init("status", "Current state", "On")], actions: [review(widget)])
        default:
            return .init(actions: [review(widget)], message: widget.summary)
        }
    }

    private static func review(_ widget: SurfaceWidget) -> SurfaceRowAction {
        .init("Open " + widget.title, "arrow.up.right", .navigate(widget.destination))
    }

    private static func github(_ tile: SurfaceTile) -> SurfaceExtensionSnapshot {
        func pull(
            _ id: String, title: String, repo: String, checks: String, review: String, number: Int
        ) -> [String: Any] {
            [
                "id": id, "title": title, "number": number,
                "url": "https://github.com/" + repo + "/pull/\(number)", "isDraft": false,
                "updatedAt": "2026-10-09T00:00:00Z", "reviewDecision": review,
                "repository": ["nameWithOwner": repo],
                "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": checks]]]]],
            ]
        }
        let one = pull(
            "review", title: "Improve search navigation", repo: "sample/atlas", checks: "SUCCESS",
            review: "REVIEW_REQUIRED", number: 42)
        let two = pull(
            "authored", title: "Add keyboard shortcuts", repo: "sample/beacon", checks: "FAILURE",
            review: "APPROVED", number: 18)
        func group(_ nodes: [[String: Any]]) -> [String: Any] {
            ["nodes": nodes, "pageInfo": ["hasNextPage": false]]
        }
        let data = try? JSONSerialization.data(withJSONObject: [
            "data": ["authored": group([two]), "review": group([one]), "assigned": group([one])]
        ])
        return data.flatMap { try? SurfaceGitHubClient.project($0, tile: tile) } ?? .init()
    }

    private static func sampleID(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }

    private static func databases(_ tile: SurfaceTile) -> SurfaceExtensionSnapshot {
        guard
            let connection = try? DatabaseConnectionDraft(
                id: .init(rawValue: sampleID(1)), displayName: "Atlas local",
                product: .elasticsearch, host: "database.example.test",
                environmentKind: .testing, environmentLabel: "Test",
                environmentProtection: .standard,
                readOnlyPolicy: .disabled, productionPolicy: .standard
            ).definition()
        else { return .init() }
        let query = DatabaseSavedQuery(
            id: .init(rawValue: sampleID(2)), connectionID: connection.id, name: "Weekly totals",
            language: .sql,
            text: "SELECT 1", createdAt: date, updatedAt: date)
        let operation = DatabaseOperationRecordSummary(
            id: .init(rawValue: sampleID(3)), kind: "export", state: .running,
            connection: connection.identity,
            progress: .determinate(completed: 3, total: 5, unit: .pages),
            cancellationSupport: .cooperative, retryClassification: .never)
        return SurfaceDatabaseClient.project(
            connections: [connection], queries: [query], operations: [operation], tile: tile)
    }
}
