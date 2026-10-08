import Foundation

public struct SurfaceMetric: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public var fraction: Double?
    public init(_ id: String, _ title: String, _ value: String, fraction: Double? = nil) {
        self.id = id; self.title = title; self.value = value
        self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }
}

public enum SurfaceExtensionAction: Equatable, Sendable {
    case navigate(String)
    case toggle(String)
    case pickColor
    case pickEmoji
    case launchBifrost
    case cleanKeys
    case muteMicrophone
    case retryDownload(UUID)
    case cancelDownload(UUID)
    case copyClipboard(String)
    case pinClipboard(String, Bool)
    case reveal(URL)
    case openURL(URL)
}

public struct SurfaceRowAction: Equatable, Identifiable, Sendable {
    public let title: String
    public let icon: String
    public let action: SurfaceExtensionAction
    public var id: String { title }
    public init(_ title: String, _ icon: String, _ action: SurfaceExtensionAction) {
        self.title = title; self.icon = icon; self.action = action
    }
}

public struct SurfaceDataRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let title: String
    public var detail = ""
    public var value = ""
    public var icon = "circle"
    public var progress: Double?
    public var actions: [SurfaceRowAction] = []
    public init(
        _ id: String, source: String? = nil, title: String, detail: String = "",
        value: String = "", icon: String = "circle", progress: Double? = nil,
        actions: [SurfaceRowAction] = []
    ) {
        self.id = id; sourceID = source ?? id; self.title = title; self.detail = detail
        self.value = value; self.icon = icon
        self.progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.actions = actions
    }
}

public struct SurfaceExtensionSnapshot: Equatable, Sendable {
    public var metrics: [SurfaceMetric] = []
    public var rows: [SurfaceDataRow] = []
    public var actions: [SurfaceRowAction] = []
    public var message: String?
    public var updatedAt: Date?
    public var sources: [SurfaceSourceChoice] = []
    public init(
        metrics: [SurfaceMetric] = [], rows: [SurfaceDataRow] = [],
        actions: [SurfaceRowAction] = [], message: String? = nil, updatedAt: Date? = nil,
        sources: [SurfaceSourceChoice] = []
    ) {
        self.metrics = metrics; self.rows = rows; self.actions = actions
        self.message = message; self.updatedAt = updatedAt; self.sources = sources
    }
}

public struct SurfaceSourceChoice: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public init(_ id: String, _ title: String) { self.id = id; self.title = title }
}

public enum SurfaceExtensionProjection {
    private static func selected(_ source: String, tile: SurfaceTile) -> Bool {
        tile.sourceIDs?.contains(source) ?? true
    }
    public static func downloads(_ snapshot: DownloadWorkerSnapshot, tile: SurfaceTile)
        -> SurfaceExtensionSnapshot
    {
        let records = snapshot.records.filter {
            selected($0.kind?.rawValue ?? "unknown", tile: tile)
        }
        let running = records.filter { !$0.isFinished && $0.status != .queued }.count
        let failed = records.filter(\.canRetry).count
        let ordered = records.sorted {
            func priority(_ value: DownloadRecord) -> Int {
                if value.canRetry { return 3 }
                if !value.isFinished { return 2 }
                return 1
            }
            return priority($0) == priority($1)
                ? $0.createdAt > $1.createdAt : priority($0) > priority($1)
        }
        return SurfaceExtensionSnapshot(
            metrics: [
                .init("running", "Downloading", "\(running)"),
                .init("queued", "Queued", "\(records.filter { $0.status == .queued }.count)"),
                .init("failed", "Needs retry", "\(failed)"),
                .init(
                    "finished", "Completed",
                    "\(records.filter { if case .done = $0.status { true } else { false } }.count)"),
            ],
            rows: ordered.map { record in
                var actions: [SurfaceRowAction] = []
                if record.canRetry {
                    actions.append(.init("Retry", "arrow.clockwise", .retryDownload(record.id)))
                }
                if !record.isFinished {
                    actions.append(.init("Cancel", "xmark", .cancelDownload(record.id)))
                }
                if case .done = record.status, let path = record.resultPaths?.first {
                    actions.append(
                        .init("Show file", "folder", .reveal(URL(fileURLWithPath: path))))
                }
                return .init(
                    record.id.uuidString, source: record.kind?.rawValue ?? "unknown",
                    title: record.title, detail: record.detail, value: record.state.capitalized,
                    icon: "arrow.down.circle",
                    progress: record.state == "downloading" ? percentage(record.detail) : nil,
                    actions: actions
                )
            },
            message: snapshot.problem
                ?? (records.isEmpty ? "No downloads in this selection." : nil),
            updatedAt: snapshot.readAt,
            sources: DownloadKind.allCases.map { .init($0.rawValue, $0.rawValue.capitalized) })
    }
    public static func percentage(_ text: String) -> Double? {
        guard let percent = text.firstIndex(of: "%") else { return nil }
        let number = text[..<percent].reversed().prefix { $0.isNumber || $0 == "." || $0 == "-" }
            .reversed()
        guard let value = Double(String(number)), value.isFinite else { return nil }
        return min(1, max(0, value / 100))
    }
    public static func clipboard(_ entries: [ClipboardEntry], tile: SurfaceTile, now: Date = Date())
        -> SurfaceExtensionSnapshot
    {
        let filtered = entries.filter { selected($0.kind.rawValue, tile: tile) }
        let ordered = filtered.sorted {
            $0.pinned == $1.pinned ? $0.createdAt > $1.createdAt : $0.pinned
        }
        return .init(
            metrics: [
                .init("total", "Recent items", "\(filtered.count)"),
                .init("pinned", "Pinned", "\(filtered.filter(\.pinned).count)"),
            ],
            rows: ordered.map {
                .init(
                    $0.id, source: $0.kind.rawValue, title: $0.displayPreview,
                    detail: [
                        $0.sourceApp,
                        ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file),
                    ].compactMap { $0 }.joined(separator: " · "),
                    value: $0.pinned ? "Pinned" : $0.kind.rawValue.capitalized,
                    icon: "doc.on.clipboard",
                    actions: [
                        .init("Copy", "doc.on.doc", .copyClipboard($0.id)),
                        .init($0.pinned ? "Unpin" : "Pin", "pin", .pinClipboard($0.id, !$0.pinned)),
                    ])
            }, message: filtered.isEmpty ? "No clipboard entries in this selection." : nil,
            updatedAt: now,
            sources: ClipboardEntry.Kind.allCases.map {
                .init($0.rawValue, $0.rawValue.capitalized)
            })
    }
    public static func machines(_ snapshot: MachineHealthSnapshot, tile: SurfaceTile)
        -> SurfaceExtensionSnapshot
    {
        let machines = snapshot.machines.filter { selected($0.id, tile: tile) }
        var metrics: [SurfaceMetric] = [.init("total", "Registered", "\(machines.count)")]
        if snapshot.skipped {
            metrics.insert(.init("status", "Health monitoring", "Off"), at: 0)
        } else {
            metrics.insert(
                contentsOf: [
                    .init("online", "Reachable", "\(machines.filter(\.reachable).count)"),
                    .init("offline", "Unreachable", "\(machines.filter { !$0.reachable }.count)"),
                ], at: 0)
        }
        return .init(
            metrics: metrics,
            rows: machines.map {
                .init(
                    $0.id, title: $0.name, detail: $0.detail ?? "",
                    value: snapshot.skipped ? "Unknown" : $0.reachable ? "Online" : "Offline",
                    icon: "desktopcomputer",
                    actions: [.init("Open fleet", "arrow.up.right", .navigate("machines"))])
            },
            message: snapshot.skipped
                ? "Reachability monitoring is off."
                : (machines.isEmpty ? "No machines in this selection." : nil),
            updatedAt: snapshot.checkedAt, sources: snapshot.machines.map { .init($0.id, $0.name) })
    }
    public static func attention(_ snapshot: AttentionPageSnapshot, tile: SurfaceTile)
        -> SurfaceExtensionSnapshot
    {
        let summary = snapshot.summary
        let entities = summary.entities.filter { selected($0.source.rawValue, tile: tile) }
        let active =
            tile.sourceIDs == nil ? summary.activeDuration : entities.reduce(0) { $0 + $1.duration }
        var metrics: [SurfaceMetric] = [.init("active", "Active today", duration(active))]
        if tile.sourceIDs == nil {
            metrics += [
                .init("focus", "Focused", duration(summary.totals.deepWork)),
                .init("switches", "App switches", "\(summary.contextSwitches)"),
                .init("agents", "Agent work", duration(summary.totals.agentWorking)),
            ]
        }
        return .init(
            metrics: metrics,
            rows: entities.sorted { $0.duration > $1.duration }.map {
                .init(
                    $0.id, source: $0.source.rawValue, title: $0.name, detail: $0.category.name,
                    value: duration($0.duration), icon: $0.domain == nil ? "app" : "globe",
                    progress: active > 0 ? $0.duration / active : nil)
            },
            message: !snapshot.hasStoredEvents ? "Attention has not recorded activity yet." : nil,
            updatedAt: summary.to,
            sources: Array(Set(summary.entities.map { $0.source.rawValue })).sorted().map {
                .init($0, $0.capitalized)
            })
    }
    public static func maintenance(_ snapshot: AppMaintenanceSnapshot, tile: SurfaceTile)
        -> SurfaceExtensionSnapshot
    {
        let updates = snapshot.updates.filter { selected($0.source.rawValue, tile: tile) }
        return .init(
            metrics: [
                .init("updates", "Available updates", "\(updates.count)"),
                .init("installed", "Installed apps", "\(snapshot.applications.count)"),
            ],
            rows: updates.map {
                .init(
                    $0.id, source: $0.source.rawValue, title: $0.name,
                    detail: $0.currentVersion + " → " + $0.availableVersion,
                    value: $0.source.title, icon: "shippingbox",
                    actions: [.init("Review update", "arrow.up.right", .navigate("appMaintenance"))]
                )
            },
            message: updates.isEmpty ? "No cached updates in this selection." : nil,
            updatedAt: updates.map(\.checkedAt).max() ?? snapshot.homebrewCachedAt,
            sources: AppUpdateSource.allCases.map { .init($0.rawValue, $0.title) })
    }
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "Unavailable" }
        let minutes = Int(min(525_600, max(0, seconds / 60)))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct SurfaceExtensionRequestKey: Hashable {
    let widget: String
    let sources: Set<String>?
    let content: Set<String>?
    init(_ tile: SurfaceTile) {
        widget = tile.widget.rawValue
        sources = tile.sourceIDs
        content = tile.contentKinds
    }
}
struct SurfaceExtensionRefreshKey: Hashable {
    let active: Bool
    let request: SurfaceExtensionRequestKey
    let retry: Int
}
