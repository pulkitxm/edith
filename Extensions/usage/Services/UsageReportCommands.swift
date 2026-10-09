import EdithExtensionSupport
import Foundation

actor UsageReportCommands {
    private let controller: UsageWorkerController
    private let store: SurfaceUsageStore
    private let directory: URL
    private let forgetMachine: @Sendable (UUID) async throws -> Void
    private var exported: Data?
    private var exportID: UUID?
    private var exportExpiry: Task<Void, Never>?
    private var stopped = false

    init(
        controller: UsageWorkerController, store: SurfaceUsageStore, directory: URL = Repo.dataDir,
        forgetMachine: (@Sendable (UUID) async throws -> Void)? = nil
    ) {
        self.controller = controller; self.store = store; self.directory = directory
        self.forgetMachine =
            forgetMachine ?? { try UsageMachinesPeer.forget(machineID: $0, directory: directory) }
    }

    func shutdown() { stopped = true; clearExport() }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, payload.count <= 131_072,
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        switch command {
        case "usage.status":
            try empty(object)
            let state = await MainActor.run {
                [
                    "refreshing": controller.refreshing,
                    "failure": controller.failure as Any? ?? NSNull(),
                    "notice": controller.notice as Any? ?? NSNull(),
                ] as [String: Any]
            }
            return try encode(state)
        case "usage.refresh":
            guard Set(object.keys).isSubset(of: ["machinePolicy"]),
                object["machinePolicy"] == nil || object["machinePolicy"] is String,
                let policy = ["skip": UsageMachineRefreshPolicy.skip, "due": .due, "all": .all][
                    object["machinePolicy"] as? String ?? "due"]
            else { throw ExtensionPeerError.invalidRequest }
            let id = try await MainActor.run { try controller.requestRefresh(policy: policy) }
            return try encode(["runID": id])
        case "usage.refresh.cancel":
            try empty(object)
            await controller.cancelRefresh()
            return try encode(["cancelled": true])
        case "usage.limits.refresh":
            try empty(object)
            try await MainActor.run { try controller.requestLimitsRefresh() }
            return try encode(["started": true])
        case "usage.machines.select":
            guard Set(object.keys) == ["machineID", "included"],
                let text = object["machineID"] as? String,
                let id = UUID(uuidString: text), let included = object["included"] as? Bool,
                await MainActor.run(body: {
                    SurfaceHostContext.current?.activeIDs.contains("machines") == true
                        && MachineRegistry.machines().contains(where: { $0.id == id })
                })
            else { throw ExtensionPeerError.invalidRequest }
            await MainActor.run {
                var selected = Set(
                    SharedDefaults.store.stringArray(forKey: UsageMachinesPeer.selectedDefaultsKey)
                        ?? [])
                if included {
                    selected.insert(id.uuidString)
                } else {
                    selected.remove(id.uuidString)
                }
                SharedDefaults.store.set(
                    selected.sorted(), forKey: UsageMachinesPeer.selectedDefaultsKey)
                if let group = DashboardModel.shared.machineGroups.first(where: {
                    $0.id.lowercased() == id.uuidString.lowercased()
                }) {
                    DashboardModel.shared.showMachine(group, included)
                }
            }
            return try encode(["included": included])
        case "usage.machines.forget":
            guard Set(object.keys) == ["machineID", "confirm"], object["confirm"] as? Bool == true,
                let text = object["machineID"] as? String, let id = UUID(uuidString: text)
            else { throw ExtensionPeerError.invalidRequest }
            await controller.cancelRefresh()
            try await forgetMachine(id)
            await store.clear()
            return try encode(["forgotten": true])
        case "usage.sources":
            try empty(object)
            let sources = try await store.sources()
            return try encode(sources.map { ["id": $0.id, "title": $0.title] })
        case "usage.summary", "usage.daily", "usage.providers", "usage.models":
            let tile = try query(object)
            let value = try await store.snapshot(tile: tile)
            switch command {
            case "usage.daily":
                return try encode(
                    value.days.map {
                        ["date": $0.id, "tokens": $0.tokens, "cost": $0.cost] as [String: Any]
                    })
            case "usage.providers", "usage.models":
                let rows = command == "usage.providers" ? value.providers : value.models
                return try encode(
                    rows.prefix(100).map {
                        [
                            "id": $0.id, "title": $0.title, "tokens": $0.total.tokens,
                            "cost": $0.total.cost,
                        ] as [String: Any]
                    })
            default:
                return try encode([
                    "today": total(value.today), "week": total(value.week),
                    "period": total(value.total), "activeDays": value.activeDays,
                ])
            }
        case "usage.share":
            guard let cardText = object["card"] as? String,
                let card = UsageShareCard(rawValue: cardText)
            else { throw ExtensionPeerError.invalidRequest }
            var selection = object; selection.removeValue(forKey: "card")
            let tile = try query(selection)
            let value = try await store.snapshot(tile: tile)
            let snapshot = UsageShareSnapshot(
                days: value.days.map { .init(period: $0.id, tokens: $0.tokens, cost: $0.cost) },
                agentCount: value.providers.count,
                repositoryCount: try repositoryCount(tile: tile, periods: Set(value.days.map(\.id)))
            )
            let image = try await MainActor.run {
                try UsageShareRenderer.pngData(snapshot: snapshot, card: card)
            }
            try Task.checkCancellation()
            guard image.count <= 4_194_304 else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                UsageSharedImage(filename: card.filenameStem + ".png", data: image))
        case "usage.projects":
            let tile = try query(object)
            let data = try UsageDataFiles.readRegularFile(
                at: directory.appendingPathComponent("usage.json"), maximumBytes: 67_108_864)
            guard let data, UsageHistory.isValidDocument(data),
                let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let daily = document["daily"] as? [[String: Any]]
            else { throw ExtensionPeerError.unavailable }
            let rows = daily.suffix(tile.days).flatMap { $0["projects"] as? [[String: Any]] ?? [] }
                .filter { row in
                    guard let selected = tile.sourceIDs else { return true }
                    let sources = Set((row["bySource"] as? [String: Any])?.keys.map { $0 } ?? [])
                    return !selected.isDisjoint(with: sources)
                }.prefix(100)
            return try encode(Array(rows))
        case "usage.attribution.list":
            try empty(object)
            let cache = UsageAttributionCache.load(dataDir: directory)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache)
            guard data.count <= 1_048_576 else {
                throw ExtensionPeerError.rejected(
                    "Use the dashboard to review this larger attribution history.")
            }
            return data
        case "usage.attribution.reset":
            guard Set(object.keys) == ["confirm"], object["confirm"] as? Bool == true else {
                throw ExtensionPeerError.invalidRequest
            }
            try UsageAttributionCache.reset(dataDir: directory)
            return try encode(["reset": true])
        case "usage.history.export":
            try empty(object)
            guard
                let data = try UsageDataFiles.readRegularFile(
                    at: directory.appendingPathComponent("usage.json"), maximumBytes: 67_108_864),
                UsageHistory.isValidDocument(data)
            else { throw ExtensionPeerError.unavailable }
            clearExport()
            exported = data; exportID = UUID()
            exportExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await self?.clearExport()
            }
            return try encode([
                "exportID": exportID!.uuidString, "byteCount": data.count,
                "sha256": UsageMachinesPeer.hash(data),
            ])
        case "usage.history.chunk":
            guard Set(object.keys) == ["exportID", "offset"],
                let text = object["exportID"] as? String, UUID(uuidString: text) == exportID,
                let offset = object["offset"] as? Int, let exported,
                (0..<exported.count).contains(offset)
            else { throw ExtensionPeerError.invalidRequest }
            let end = min(exported.count, offset + 262_144)
            let data = try JSONEncoder().encode(
                UsageMachinesPeer.Chunk(
                    offset: offset, data: exported.subdata(in: offset..<end),
                    finished: end == exported.count))
            if end == exported.count { clearExport() }
            return data
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private func clearExport() {
        exportExpiry?.cancel(); exportExpiry = nil; exported = nil; exportID = nil
    }

    func repositoryCount(tile: SurfaceTile, periods: Set<String>) throws -> Int {
        guard
            let data = try UsageDataFiles.readRegularFile(
                at: directory.appendingPathComponent("usage.json"), maximumBytes: 67_108_864)
        else { throw ExtensionPeerError.unavailable }
        let document = try JSONDecoder().decode(DashUsage.self, from: data)
        let selected =
            tile.sourceIDs
            ?? document.defaultSources.flatMap {
                $0.isEmpty ? nil : Set($0)
            }
        var identifiers = Set<String>()
        for day in document.daily where periods.contains(day.period) {
            for project in day.projects ?? [] {
                let amounts = (project.bySource ?? [:]).filter {
                    selected?.contains($0.key) ?? true
                }
                let tokens = amounts.values.reduce(0) { $0 + max(0, $1.tokens ?? 0) }
                let cost = amounts.values.reduce(0) { $0 + max(0, $1.cost ?? 0) }
                let matches =
                    selected == nil && (project.tokens ?? 0 > 0 || project.cost ?? 0 > 0)
                    || tokens > 0 || cost > 0
                if matches {
                    identifiers.insert(DashboardComputation.repositoryID(project))
                }
            }
        }
        return identifiers.count
    }

    private func query(_ object: [String: Any]) throws -> SurfaceTile {
        guard Set(object.keys).isSubset(of: ["days", "sourceIDs"]),
            object["days"] == nil || object["days"] is Int,
            (1...365).contains(object["days"] as? Int ?? 30),
            object["sourceIDs"] == nil || object["sourceIDs"] is [String]
        else { throw ExtensionPeerError.invalidRequest }
        var tile = SurfaceTile(.usage); tile.days = object["days"] as? Int ?? 30
        if let sources = object["sourceIDs"] as? [String] {
            guard sources.count <= 100,
                sources.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 && !$0.utf8.contains(0) }
                )
            else { throw ExtensionPeerError.invalidRequest }
            tile.sourceIDs = Set(sources)
        }
        return tile
    }

    private func total(_ value: SurfaceUsageSnapshot.Total) -> [String: Double] {
        ["cost": value.cost, "tokens": value.tokens]
    }
    private func empty(_ object: [String: Any]) throws {
        guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
    }
    private func encode(_ value: Any) throws -> Data {
        try Task.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 1_048_576, !stopped else { throw ExtensionPeerError.invalidRequest }
        return data
    }
}

private struct UsageSharedImage: Encodable { let filename: String; let data: Data }
