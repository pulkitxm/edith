import Foundation

public enum SurfaceCommandService {
    @MainActor
    public static func execute(
        providerID: String, command: String, payload: Data,
        snapshot: @MainActor (SurfaceTile) async throws -> SurfaceSnapshot,
        perform: @MainActor (String) async throws -> Void,
        adjust: (@MainActor (String, Double) async throws -> Void)? = nil,
        privacyValues: @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) async throws -> Data {
        let request: SurfaceSnapshotRequest
        switch command {
        case "surface.snapshot":
            request = try SurfaceSnapshotRequest.decode(payload, providerID: providerID)
        case "surface.perform":
            let action = try SurfaceActionRequest.decode(payload, providerID: providerID)
            request = action.snapshot
            guard !SurfacePrivacyState.hides(request.tile.widget, values: privacyValues()) else {
                throw ExtensionPeerError.invalidRequest
            }
            let current = project(try await snapshot(request.tile), tile: request.tile)
            _ = try current.encoded()
            guard current.providerID == providerID else { throw ExtensionPeerError.invalidRequest }
            if let value = action.value {
                guard adjust != nil, value.isFinite, (0...1).contains(value),
                    ((current.sliders ?? []) + current.rows.flatMap { $0.sliders ?? [] }).contains(
                        where: { $0.id == action.actionID })
                else { throw ExtensionPeerError.invalidRequest }
            } else {
                guard
                    (current.actions + current.rows.flatMap(\.actions)).contains(where: {
                        $0.id == action.actionID
                    })
                else { throw ExtensionPeerError.invalidRequest }
            }
            try Task.checkCancellation()
            guard !SurfacePrivacyState.hides(request.tile.widget, values: privacyValues()) else {
                throw ExtensionPeerError.invalidRequest
            }
            if let value = action.value, let adjust {
                try await adjust(action.actionID, value)
            } else {
                try await perform(action.actionID)
            }
        default:
            throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        if SurfacePrivacyState.hides(request.tile.widget, values: privacyValues()) {
            return try SurfaceSnapshot(providerID: providerID, message: "Hidden while presenting.")
                .encoded()
        }
        let current = project(try await snapshot(request.tile), tile: request.tile)
        try Task.checkCancellation()
        guard current.providerID == providerID else { throw ExtensionPeerError.invalidRequest }
        if SurfacePrivacyState.hides(request.tile.widget, values: privacyValues()) {
            return try SurfaceSnapshot(providerID: providerID, message: "Hidden while presenting.")
                .encoded()
        }
        return try current.encoded()
    }

    public static func project(_ snapshot: SurfaceSnapshot, tile: SurfaceTile) -> SurfaceSnapshot {
        var projected = snapshot
        projected.metrics = snapshot.metrics.filter { tile.shows($0.id) }
        projected.actions = actions(snapshot.actions, tile: tile)
        projected.sliders = sliders(snapshot.sliders, tile: tile)
        projected.rows =
            tile.shows("items")
            ? Array(
                snapshot.rows.filter {
                    (tile.sourceIDs?.contains($0.sourceID) ?? true)
                        && ($0.field.map { tile.shows($0) } ?? true)
                }.prefix(tile.itemLimit)
            ).map { row in
                SurfaceDataRow(
                    row.id, sourceID: row.sourceID, title: row.title,
                    detail: tile.showDetails && tile.shows("metadata") ? row.detail : "",
                    value: tile.shows("status") ? row.value : "", icon: row.icon,
                    progress: tile.shows("progress") ? row.progress : nil, field: row.field,
                    actions: actions(row.actions, tile: tile),
                    sliders: sliders(row.sliders, tile: tile) ?? [])
            } : []
        if !tile.shows("status") { projected.message = nil }
        if !tile.shows("updated") { projected.updatedAt = nil }
        return projected
    }

    private static func actions(_ actions: [SurfaceAction], tile: SurfaceTile) -> [SurfaceAction] {
        guard tile.showActions else { return [] }
        return actions.filter { $0.field.map { tile.shows($0) } ?? true }
    }
    private static func sliders(_ values: [SurfaceSlider]?, tile: SurfaceTile) -> [SurfaceSlider]? {
        guard tile.showActions else { return nil }
        let controls = values?.filter { $0.field.map { tile.shows($0) } ?? true } ?? []
        return controls.isEmpty ? nil : controls
    }

}
