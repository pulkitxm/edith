@_implementationOnly import EdithExtensionSupport
import Foundation

@MainActor
final class AttentionSurface {
    private let repository: AttentionRepository
    private let service: AttentionBackgroundService
    private let privacyValues: @MainActor () -> [String: String]
    init(
        repository: AttentionRepository, service: AttentionBackgroundService,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.repository = repository; self.service = service
        self.privacyValues = privacyValues
    }
    func execute(_ command: String, payload: Data) async throws -> Data {
        try await SurfaceCommandService.execute(
            providerID: "attention", command: command, payload: payload,
            snapshot: { [self] tile in try await snapshot(tile) },
            perform: { [self] action in
                if action == "focus.finish", let session = repository.activeFocus() {
                    _ = try repository.endFocus(now: max(Date(), session.startedAt))
                } else if action.hasPrefix("focus.start."), repository.activeFocus() == nil,
                    let minutes = Int(action.dropFirst("focus.start.".count)),
                    (1...1440).contains(minutes)
                {
                    _ = try repository.startFocus(name: "Focus", duration: Double(minutes * 60))
                } else {
                    throw ExtensionPeerError.invalidRequest
                }
            }, privacyValues: privacyValues)
    }
    func snapshot(_ tile: SurfaceTile, now: Date = Date()) async throws -> SurfaceSnapshot {
        if tile.widget == .focus { return focusSnapshot(tile, now: now) }
        let snapshot = try await service.summary(
            .init(
                from: Calendar.current.startOfDay(for: now), to: now,
                parts: [.overview, .breakdown, .focus, .agents]))
        let summary = snapshot.summary
        let entities = summary.entities.filter {
            tile.sourceIDs?.contains($0.source.rawValue) ?? true
        }
        let active =
            tile.sourceIDs == nil ? summary.activeDuration : entities.reduce(0) { $0 + $1.duration }
        var metrics: [SurfaceMetric] = [
            .init("active", "Active today", AttentionFormat.duration(active))
        ]
        if tile.sourceIDs == nil {
            metrics += [
                .init("focus", "Focused", AttentionFormat.duration(summary.totals.deepWork)),
                .init("switches", "App switches", String(summary.contextSwitches)),
                .init(
                    "agents", "Agent work", AttentionFormat.duration(summary.totals.agentWorking)),
            ]
        }
        return SurfaceSnapshot(
            providerID: "attention", metrics: metrics,
            rows: Array(entities.sorted { $0.duration > $1.duration }.prefix(100)).map {
                SurfaceDataRow(
                    String($0.id.prefix(512)), sourceID: $0.source.rawValue,
                    title: String($0.name.prefix(1024)), detail: $0.category.name,
                    value: AttentionFormat.duration($0.duration),
                    icon: $0.domain == nil ? "app" : "globe",
                    progress: active > 0 ? min(1, $0.duration / active) : nil)
            },
            sources: AttentionEventSource.allCases.map {
                .init($0.rawValue, $0.rawValue.capitalized)
            },
            message: snapshot.hasStoredEvents ? nil : "Attention has not recorded activity yet.",
            updatedAt: summary.to)
    }
    func focusSnapshot(_ tile: SurfaceTile, now: Date) -> SurfaceSnapshot {
        if let session = repository.activeFocus() {
            let remaining = max(
                0, session.plannedDuration - now.timeIntervalSince(session.startedAt))
            return SurfaceSnapshot(
                providerID: "attention",
                metrics: [.init("remaining", "Remaining", AttentionFormat.duration(remaining))],
                rows: [
                    .init(
                        session.id, sourceID: "focus", title: String(session.name.prefix(300)),
                        field: "session")
                ],
                actions: [.init("focus.finish", "Finish", "stop.fill")], updatedAt: now)
        }
        return SurfaceSnapshot(
            providerID: "attention",
            metrics: [.init("remaining", "Focus", "\(tile.focusMinutes) min")],
            actions: [.init("focus.start.\(tile.focusMinutes)", "Start focus", "play.fill")],
            updatedAt: now)
    }
}
