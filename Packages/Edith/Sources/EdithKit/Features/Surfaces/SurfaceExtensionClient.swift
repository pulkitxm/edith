import AppKit
import Foundation

public actor SurfaceExtensionClient {
    public static let shared = SurfaceExtensionClient()
    private let client: AgentClient
    private var previousCPU: CPUTicks?
    private var cache: [String: (Date, SurfaceExtensionSnapshot)] = [:]
    private var requests: [String: Task<SurfaceExtensionSnapshot, Error>] = [:]
    public init(client: AgentClient = .shared) { self.client = client }

    public func snapshot(_ tile: SurfaceTile, force: Bool = false) async throws
        -> SurfaceExtensionSnapshot
    {
        let sources = tile.sourceIDs?.sorted().joined(separator: "|") ?? "*"
        let key = tile.widget.rawValue + ":" + sources
        let interval = Self.interval(tile.widget)
        if !force, let cached = cache[key], Date().timeIntervalSince(cached.0) < interval {
            return cached.1
        }
        if let pending = requests[key] { return try await pending.value }
        let task = Task { try await self.read(tile) }
        requests[key] = task
        defer { requests[key] = nil }
        let value = try await task.value
        if cache.count >= 100 { cache.removeAll() }
        cache[key] = (Date(), value)
        return value
    }
    public static func interval(_ widget: SurfaceWidget) -> Double {
        switch widget {
        case .ability("systemStats"), .ability("system"): 2
        case .ability("downloads"), .ability("audioMixer"), .ability("timeLapse"): 5
        case .ability("clipboard"), .ability("notchShelf"), .desk: 10
        default: 30
        }
    }
    private func read(_ tile: SurfaceTile) async throws -> SurfaceExtensionSnapshot {
        guard tile.widget.available(in: SharedDefaults.store) else {
            return .init(message: "Enable this extension to show its data and controls.")
        }
        switch tile.widget {
        case .machines:
            return SurfaceExtensionProjection.machines(
                try await client.snapshotAsync(MachineHealthSnapshot.self, topic: .machines),
                tile: tile)
        case .desk, .ability("clipboard"), .ability("colorPicker"):
            if tile.widget == .desk
                && !SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.enabled)
            {
                return .init(
                    rows: ExtensionRegistry.entries.filter {
                        $0.suite == .desk && SharedDefaults.store.bool(forKey: $0.defaultsKey)
                    }.map {
                        .init(
                            $0.id, title: $0.title, detail: $0.subtitle, icon: $0.symbolName,
                            actions: [.init("Open", "arrow.up.right", .navigate($0.id))])
                    }, message: "Enable Clipboard to include recent items.")
            }
            let snapshot = try await AgentClipboardClient(client: client).snapshot(
                .init(limit: 200))
            var selected = tile
            if tile.widget == .ability("colorPicker") { selected.sourceIDs = nil }
            var entries = snapshot.entries
            if tile.widget == .ability("colorPicker") {
                entries = entries.filter {
                    $0.isTextual && ClipboardColorValue(parsing: $0.displayPreview) != nil
                }
            }
            var value = SurfaceExtensionProjection.clipboard(entries, tile: selected)
            if tile.widget == .desk || tile.widget == .ability("colorPicker") {
                value.actions.append(.init("Pick color", "eyedropper", .pickColor))
            }
            return value
        case .media, .ability("downloads"):
            if tile.widget == .media
                && !SharedDefaults.store.bool(forKey: AppStorageKeys.Downloads.enabled)
            {
                return .init(
                    rows: ExtensionRegistry.entries.filter {
                        $0.suite == .media && SharedDefaults.store.bool(forKey: $0.defaultsKey)
                    }.map {
                        .init(
                            $0.id, title: $0.title, detail: $0.subtitle, icon: $0.symbolName,
                            actions: [.init("Open", "arrow.up.right", .navigate($0.id))])
                    }, message: "Enable Downloads to include the live queue.")
            }
            return SurfaceExtensionProjection.downloads(
                try await AgentDownloadClient(client: client).snapshot(), tile: tile)
        case .ability("attention"):
            let now = Date()
            return SurfaceExtensionProjection.attention(
                try await AttentionBackgroundClient.summary(
                    .init(
                        from: Calendar.current.startOfDay(for: now), to: now,
                        parts: [.overview, .breakdown, .focus, .agents]), client: client),
                tile: tile)
        case .ability("homebrew"):
            let snapshot = await HomebrewListingStore(
                fileURL: AppData.supportDir.appendingPathComponent("homebrew-listing.json")
            ).load()
            let packages = (snapshot?.packages.values.flatMap { $0 } ?? []).filter {
                tile.sourceIDs?.contains($0.kind.rawValue) ?? true
            }
            return .init(
                metrics: [
                    .init("packages", "Installed packages", "\(packages.count)"),
                    .init("updates", "Outdated", "\(packages.filter(\.outdated).count)"),
                ],
                rows: packages.sorted { $0.outdated && !$1.outdated }.map {
                    .init(
                        $0.id, source: $0.kind.rawValue, title: $0.displayName,
                        detail: $0.versionSummary,
                        value: $0.outdated ? "Update available" : $0.kind.title, icon: "cube.box",
                        actions: [.init("Review package", "arrow.up.right", .navigate("homebrew"))])
                },
                message: snapshot == nil ? "Open Packages to load the installed inventory." : nil,
                sources: HomebrewPackageKind.allCases.map { .init($0.rawValue, $0.pluralTitle) })
        case .ability("appMaintenance"):
            let store = AppMaintenanceSnapshotStore(
                fileURL: AppData.supportDir.appendingPathComponent("app-maintenance-snapshot.json"))
            if let snapshot = await store.load() {
                return SurfaceExtensionProjection.maintenance(snapshot, tile: tile)
            }
            let snapshot = try await client.snapshotAsync(
                UpdateDiscoverySnapshot.self, topic: .updates)
            return .init(
                metrics: [.init("updates", "Available updates", "\(snapshot.available)")],
                rows: snapshot.sources.map { .init($0, title: $0, icon: "shippingbox") },
                message: "Open Updates to review versions and available packages.",
                updatedAt: snapshot.checkedAt)
        case .ability("cleaner"), .ability("blitztree"):
            let snapshot = try await client.snapshotAsync(
                CleanerEstimateSnapshot.self, topic: .cleaner)
            return .init(
                metrics: [
                    .init(
                        "space", "Reclaimable",
                        ByteCountFormatter.string(
                            fromByteCount: snapshot.reclaimableBytes, countStyle: .file)),
                    .init("categories", "Categories", "\(snapshot.categories)"),
                ],
                actions: [
                    .init("Review space", "arrow.up.right", .navigate(tile.widget.destination))
                ], updatedAt: snapshot.scannedAt)
        case .ability("companion"):
            let snapshot = try await client.snapshotAsync(
                CompanionHealthSnapshot.self, topic: .companion)
            return .init(
                metrics: [
                    .init(
                        "status", "Service",
                        snapshot.skipped
                            ? "Not set up"
                            : snapshot.reachable
                                ? (snapshot.degraded ? "Degraded" : "Healthy") : "Offline")
                ],
                rows: snapshot.checks.map {
                    .init(
                        $0.name, title: $0.name, detail: $0.detail,
                        value: $0.ok ? "Ready" : "Needs attention",
                        icon: $0.ok ? "checkmark.circle" : "exclamationmark.circle")
                },
                message: snapshot.failure, updatedAt: snapshot.checkedAt)
        case .ability("seoAudit"):
            let projects = try await SEOAuditController().list()
            let selected = projects.filter { tile.sourceIDs?.contains($0.id.uuidString) ?? true }
            return .init(
                metrics: [
                    .init("projects", "Projects", "\(selected.count)"),
                    .init(
                        "pages", "Audited pages",
                        "\(selected.reduce(0) { $0 + ($1.latestRun?.pageCount ?? 0) })"),
                    .init(
                        "issues", "Issues",
                        "\(selected.reduce(0) { $0 + ($1.latestRun?.issueCount ?? 0) })"),
                ],
                rows: selected.map {
                    .init(
                        $0.id.uuidString, title: $0.name, detail: $0.baseURL,
                        value: $0.latestRun?.averageScore.map { "\($0)%" } ?? "Not run",
                        icon: "globe")
                },
                message: selected.isEmpty ? "No site audit projects in this selection." : nil,
                updatedAt: projects.map(\.updatedAt).max(),
                sources: projects.map { .init($0.id.uuidString, $0.name) })
        case .ability("notchShelf"):
            let items = ShelfIndex.load().sorted { $0.addedAt > $1.addedAt }
            return .init(
                metrics: [.init("files", "Shelf files", "\(items.count)")],
                rows: items.map {
                    let url = ShelfIndex.fileURL(for: $0)
                    return .init(
                        $0.id.uuidString, title: $0.name, icon: "doc",
                        actions: [.init("Show file", "folder", .reveal(url))])
                },
                message: items.isEmpty
                    ? "Drop files onto the Notch file shelf to keep them nearby." : nil,
                updatedAt: Date())
        case .ability("studio"):
            let items = try StudioMediaLibrary.list().sorted { $0.addedAt > $1.addedAt }
            return .init(
                metrics: [.init("files", "Library files", "\(items.count)")],
                rows: items.map {
                    .init(
                        $0.url.absoluteString, title: $0.name,
                        value: $0.url.pathExtension.uppercased(), icon: "photo.on.rectangle",
                        actions: [.init("Show file", "folder", .reveal($0.url))])
                }, message: items.isEmpty ? "Add media to Studio to keep it available here." : nil,
                updatedAt: Date())
        case .ability("latex"):
            let projects = try LaTeXProjectStore().load()
            let selected = projects.filter { tile.sourceIDs?.contains($0.id.uuidString) ?? true }
            return .init(
                metrics: [
                    .init("projects", "Documents", "\(selected.count)"),
                    .init(
                        "reviews", "Pull requests",
                        "\(selected.filter { $0.pullRequest != nil }.count)"),
                ],
                rows: selected.map {
                    .init(
                        $0.id.uuidString, title: $0.name,
                        detail: $0.location == .disk
                            ? URL(fileURLWithPath: $0.sourcePath).lastPathComponent : $0.repository,
                        value: $0.pullRequest.map { "PR #\($0)" } ?? $0.compiler.title,
                        icon: "doc.richtext",
                        actions: [.init("Open document", "arrow.up.right", .navigate("latex"))])
                },
                message: selected.isEmpty ? "Add a LaTeX document to keep it available here." : nil,
                sources: projects.map { .init($0.id.uuidString, $0.name) })
        case .ability("bifrost"):
            let index = BifrostIndexStore.shared.load()
            return .init(
                metrics: [.init("apps", "Indexed apps", "\(index?.applications.count ?? 0)")],
                rows: Array((index?.applications ?? []).prefix(40)).map {
                    .init(
                        $0.id, title: $0.name, icon: "app",
                        actions: [
                            .init(
                                "Launch", "arrow.up.right", .openURL(URL(fileURLWithPath: $0.path)))
                        ])
                }, actions: [.init("Open launcher", "magnifyingglass", .launchBifrost)],
                updatedAt: index?.generatedAt)
        case .ability("plugins"):
            let agents = SkillAgentCatalog.detected()
            return .init(
                metrics: [
                    .init("agents", "Detected agents", "\(agents.count)"),
                    .init("skills", "Available skills", "\(EdithSkillLibrary.skills.count)"),
                ],
                rows: agents.map { .init($0.id, title: $0.name, icon: "terminal") },
                actions: [.init("Manage skills", "arrow.up.right", .navigate("plugins"))],
                updatedAt: Date())
        case .ability("virtualCamera"):
            let state = VirtualCameraStore.load()
            return .init(
                metrics: [.init("scenes", "Saved scenes", "\(state.scenes.count)")],
                rows: state.scenes.map {
                    .init(
                        $0.id.uuidString, title: $0.name,
                        value: state.activeSceneID == $0.id ? "Selected" : "", icon: "web.camera")
                },
                message: "Open Camera to preview, frame, or start the camera.", updatedAt: Date())
        case .ability("systemStats"):
            let ticks = SystemStatsReader.readCPUTicks()
            let cpu = previousCPU.flatMap { old in
                ticks.map { SystemStatsReader.cpuUsage(previous: old, current: $0) }
            }
            previousCPU = ticks
            let memory = SystemStatsReader.memoryUsedPercent()
            let volume = try? AppData.supportDir.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
            ])
            var metrics: [SurfaceMetric] = [
                .init(
                    "cpu", "CPU", cpu.map { String(format: "%.0f%%", $0) } ?? "Sampling",
                    fraction: cpu.map { $0 / 100 }),
                .init(
                    "memory", "Memory used", String(format: "%.0f%%", memory),
                    fraction: memory / 100),
            ]
            if let free = volume?.volumeAvailableCapacityForImportantUsage,
                let total = volume?.volumeTotalCapacity, total > 0
            {
                metrics.append(
                    .init(
                        "disk", "Storage free",
                        ByteCountFormatter.string(fromByteCount: free, countStyle: .file),
                        fraction: 1 - Double(free) / Double(total)))
            }
            return .init(metrics: metrics, updatedAt: Date())
        case .ability("system"):
            let apps = await MainActor.run {
                NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                    .map {
                        SurfaceDataRow(
                            String($0.processIdentifier), source: $0.bundleIdentifier,
                            title: $0.localizedName ?? "Application",
                            value: $0.isActive ? "Active" : "", icon: "app")
                    }
            }
            return .init(
                metrics: [.init("apps", "Running apps", "\(apps.count)")], rows: apps,
                actions: [.init("Clean keys", "keyboard", .cleanKeys)], updatedAt: Date())
        default:
            return Self.control(tile.widget)
        }
    }
    private static func control(_ widget: SurfaceWidget) -> SurfaceExtensionSnapshot {
        let defaults = SharedDefaults.store
        let setting: String?
        switch widget {
        case .ability("keepAwake"): setting = AppStorageKeys.General.preventSleep
        case .ability("focusDim"): setting = "focusDimActive"
        case .ability("keystrokeHighlight"): setting = AppStorageKeys.KeystrokeHighlight.active
        case .ability("windowSweaters"): setting = AppStorageKeys.WindowSweaters.active
        case .ability("presenter"): setting = AppStorageKeys.Presenter.mode
        default: setting = nil
        }
        if let setting {
            let active = defaults.bool(forKey: setting)
            return .init(
                metrics: [.init("status", "Current state", active ? "On" : "Off")],
                actions: [.init(active ? "Turn off" : "Turn on", widget.icon, .toggle(setting))],
                updatedAt: Date())
        }
        if widget == .ability("micMute") {
            return .init(
                metrics: [
                    .init(
                        "status", "Microphone", defaults.bool(forKey: "micMuted") ? "Muted" : "On")
                ],
                actions: [.init("Toggle mute", "mic.slash", .muteMicrophone)], updatedAt: Date())
        }
        if widget == .ability("emoji") {
            return .init(
                actions: [.init("Choose emoji", "face.smiling", .pickEmoji)],
                message: "Choose an emoji to insert into your current app.")
        }
        if widget == .ability("lidAwake") {
            return .init(
                metrics: [
                    .init(
                        "status", "Lid awake",
                        defaults.bool(forKey: LidAwakeState.activeKey) ? "On" : "Off")
                ],
                actions: [
                    .init("Review lid controls", "laptopcomputer", .navigate(widget.destination))
                ])
        }
        return .init(
            actions: [
                .init("Open " + widget.title, "arrow.up.right", .navigate(widget.destination))
            ], message: widget.summary)
    }
}
