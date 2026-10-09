import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
final class UsageSurface {
    private let store: SurfaceUsageStore
    private let controller: UsageWorkerController
    private let limits: @Sendable () async -> LimitsTopicSnapshot
    private let open: @MainActor () -> Void
    private let privacy: @MainActor () -> [String: String]

    init(
        store: SurfaceUsageStore, controller: UsageWorkerController,
        limits: @escaping @Sendable () async -> LimitsTopicSnapshot = {
            let values = await LimitsHistory.loadLatestProviders()
            return LimitsTopicSnapshot(
                refreshedAt: values.values.map(\.date).max() ?? .distantPast,
                providers: LimitProvider.allCases.compactMap { provider in
                    values[provider].map {
                        .init(
                            provider: provider, session: $0.session, week: $0.week, fable: $0.fable,
                            grok: $0.grok)
                    }
                }, failure: nil)
        }, open: @escaping @MainActor () -> Void = { ExtensionPresentation.showWindow() },
        privacy: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.store = store; self.controller = controller; self.limits = limits; self.open = open;
        self.privacy = privacy
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try await SurfaceCommandService.execute(
            providerID: "usage", command: command, payload: payload,
            snapshot: { [weak self] tile in
                guard let self else { throw ExtensionPeerError.unavailable }
                return try await self.snapshot(tile)
            },
            perform: { [weak self] action in
                guard let self else { throw ExtensionPeerError.unavailable }
                if action == "refresh" {
                    _ = try self.controller.requestRefresh()
                } else if action == "limits-refresh" {
                    try self.controller.requestLimitsRefresh()
                } else if action == "open" || action.hasPrefix("day:") {
                    self.open()
                } else {
                    throw ExtensionPeerError.invalidRequest
                }
            }, privacyValues: privacy)
    }

    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        if SurfacePrivacyState.hides(tile.widget, values: privacy())
            || (tile.widget == .ability("usage") && privacy()["active"] == "1"
                && privacy()["blurMoney"] != "0")
        {
            return .init(providerID: "usage", message: "Hidden while presenting.")
        }
        if tile.widget == .limits { return try await limitsSnapshot(tile) }
        let value: SurfaceUsageSnapshot
        do { value = try await store.snapshot(tile: tile) } catch {
            try Task.checkCancellation()
            return .init(
                providerID: "usage", actions: actions(),
                message: "No usage data yet. Open Usage or refresh to collect activity.")
        }
        let sources = try await store.sources()
        try Task.checkCancellation()
        let metrics: [SurfaceMetric] = [
            .init("today", "Today", money(value.today.cost)),
            .init("week", "Last seven days", money(value.week.cost)),
            .init("period", "Selected period", money(value.total.cost)),
            .init("tokens", "Tokens", TokenFormatter.compact(value.total.tokens)),
        ]
        let rows =
            value.providers.prefix(tile.itemLimit).map { item in
                SurfaceDataRow(
                    "provider:"
                        + SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }
                        .joined(), sourceID: item.id, title: bounded(item.title, 256),
                    detail: tile.shows("tokens")
                        ? TokenFormatter.compact(item.total.tokens) + " tokens" : "",
                    value: money(item.total.cost), icon: "chart.pie", field: "providers")
            }
            + (tile.shows("models")
                ? value.models.prefix(tile.itemLimit).enumerated().map { index, item in
                    SurfaceDataRow(
                        "model:\(index)", sourceID: tile.sourceIDs?.sorted().first ?? "all",
                        title: bounded(item.title, 256),
                        detail: tile.shows("tokens")
                            ? TokenFormatter.compact(item.total.tokens) + " tokens" : "",
                        value: money(item.total.cost), icon: "cpu", field: "models")
                } : [])
        let points = value.days.map { day in
            SurfaceChartPoint(
                day.id, x: day.date.timeIntervalSince1970,
                y: value.chartUsesTokens ? day.tokens : day.cost,
                label: day.id,
                value: value.chartUsesTokens ? TokenFormatter.compact(day.tokens) : money(day.cost))
        }
        let charts =
            tile.widget == .activity
            ? []
            : [
                SurfaceChart(
                    "daily", "Daily activity", series: [.init("usage", "Usage", points: points)],
                    xAxis: .date, xTitle: "Day", yTitle: value.chartUsesTokens ? "Tokens" : "Cost")
            ]
        let scale = UsageCalendarScale(days: value.days)
        let calendars =
            tile.widget == .activity && !value.days.isEmpty
            ? [
                SurfaceCalendar(
                    "activity", "Daily activity",
                    days: value.days.map { day in
                        SurfaceCalendarDay(
                            day.id, date: day.id, level: scale.level(for: day),
                            value: value.chartUsesTokens
                                ? TokenFormatter.compact(day.tokens) + " tokens" : money(day.cost),
                            action: .init("day:" + day.id, "Open Usage", "calendar"))
                    })
            ] : []
        return .init(
            providerID: "usage", metrics: tile.widget == .activity ? [] : metrics,
            rows: tile.widget == .activity ? [] : Array(rows.prefix(100)), actions: actions(),
            charts: charts,
            calendars: calendars, sources: sources,
            message: controller.failure ?? value.pricingNotice ?? controller.notice,
            updatedAt: value.updatedAt)
    }

    private func limitsSnapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        let cached: LimitsTopicSnapshot
        if let current = controller.latestLimits {
            cached = current
        } else {
            cached = await limits()
        }
        try Task.checkCancellation()
        let selected = cached.providers.filter {
            tile.sourceIDs?.contains($0.provider.rawValue) ?? true
        }
        var rows: [SurfaceDataRow] = []
        for provider in selected {
            for (slot, field) in [
                (LimitWindowSlot.session, "session"), (.week, "weekly"), (.fable, "additional"),
            ] {
                guard tile.shows(field), let window = provider.window(for: slot),
                    window.percent.isFinite,
                    (window.resetsAt ?? .distantFuture) > Date()
                else { continue }
                let used = min(100, max(0, window.percent))
                var details: [String] = []
                if tile.shows("remaining") {
                    details.append("\(Int((100 - used).rounded()))% remaining")
                }
                if tile.shows("resets"), let reset = window.resetsAt {
                    details.append(
                        "Resets " + reset.formatted(date: .abbreviated, time: .shortened))
                }
                if tile.shows("account"), let allowance = provider.grok {
                    details.append(bounded(allowance.summary, 256))
                }
                rows.append(
                    .init(
                        provider.provider.rawValue + ":" + slot.rawValue,
                        sourceID: provider.provider.rawValue,
                        title: provider.provider.label + " "
                            + slot.settingsLabel(for: provider.provider),
                        detail: details.joined(separator: " · "), value: "\(Int(used.rounded()))%",
                        icon: "gauge", progress: used / 100, field: field))
            }
            if tile.shows("errors"), let error = provider.error {
                rows.append(
                    .init(
                        provider.provider.rawValue + ":error", sourceID: provider.provider.rawValue,
                        title: provider.provider.label, detail: bounded(error, 1_024),
                        icon: "exclamationmark.triangle", field: "errors"))
            }
        }
        return .init(
            providerID: "usage", metrics: [.init("providers", "Providers", String(selected.count))],
            rows: Array(rows.prefix(tile.itemLimit)),
            actions: [
                .init("limits-refresh", "Refresh limits", "arrow.clockwise"),
                .init("open", "Open Usage", "arrow.up.right"),
            ],
            sources: LimitProvider.allCases.map { .init($0.rawValue, $0.label) },
            message: rows.isEmpty
                ? "No current limits. Open Usage to connect a provider." : cached.failure,
            updatedAt: cached.refreshedAt == .distantPast ? nil : cached.refreshedAt)
    }

    private func actions() -> [SurfaceAction] {
        [
            .init("refresh", "Refresh", "arrow.clockwise"),
            .init("open", "Open Usage", "arrow.up.right"),
        ]
    }
    private func money(_ amount: Double) -> String { amount.formatted(.currency(code: "USD")) }
    private func bounded(_ value: String, _ maximum: Int) -> String {
        String(value.prefix(maximum))
    }
}
