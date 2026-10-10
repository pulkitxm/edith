import EdithExtensionSupport
import Foundation

struct UsageCompactQuotaValue: Equatable, Sendable {
    let percent: Double?
    let expired: Bool
    var fraction: Double? { percent.map { $0 / 100 } }
    var remaining: Int? { percent.map { max(0, 100 - Int($0.rounded())) } }
    var text: String {
        if expired { return "Expired" }
        return percent.map { "\(Int($0.rounded()))% used" } ?? "Unavailable"
    }
    init(_ window: LimitWindow?, now: Date = Date()) {
        expired = window?.resetsAt.map { $0.timeIntervalSince1970.isFinite && $0 <= now } ?? false
        guard let window, window.percent.isFinite, window.percent >= 0, !expired,
            window.resetsAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { percent = nil; return }
        percent = min(100, window.percent)
    }
}

struct UsageCompactLimitsSnapshot: Codable, Equatable, Sendable {
    struct Detail: Codable, Equatable, Sendable {
        let field: String
        let text: String
        init(_ field: String, _ text: String) { self.field = field; self.text = text }
    }
    struct Row: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let source: String
        let title: String
        let value: String
        let icon: String
        let progress: Double?
        let field: String
        let details: [Detail]
        init(
            _ id: String, source: String, title: String, value: String, icon: String,
            progress: Double?, field: String, details: [Detail]
        ) {
            self.id = id; self.source = source; self.title = title; self.value = value
            self.icon = icon; self.progress = progress; self.field = field; self.details = details
        }
    }
    let metrics: [SurfaceMetric]
    let rows: [Row]
    let message: String?
    let updatedAt: Date
    let sources: [SurfaceSourceChoice]

    static func project(
        _ snapshot: LimitsTopicSnapshot, tile: SurfaceTile, now: Date = Date()
    ) -> UsageCompactLimitsSnapshot {
        let providers = snapshot.providers.filter {
            tile.sourceIDs?.contains($0.provider.rawValue) ?? true
        }
        var rows: [UsageCompactLimitsSnapshot.Row] = []
        var remaining: [Int] = []
        for provider in providers {
            let windows: [(String, String, LimitWindow?)] = [
                (
                    "session", provider.provider == .cursor ? "Cursor models" : "Session (5h)",
                    provider.session
                ),
                (
                    "weekly",
                    provider.provider == .cursor
                        ? "Other models"
                        : provider.provider == .grok
                            ? GrokPeriod.title(provider.grok?.period) : "Weekly", provider.week
                ),
                ("additional", "Additional models", provider.fable),
            ]
            for (field, title, window) in windows where window != nil || field == "weekly" {
                let quota = UsageCompactQuotaValue(window, now: now)
                if let capacity = quota.remaining { remaining.append(capacity) }
                var details: [UsageCompactLimitsSnapshot.Detail] = []
                if let capacity = quota.remaining {
                    details.append(.init("remaining", "\(capacity)% remaining"))
                }
                if let reset = window?.resetsAt, reset.timeIntervalSince1970.isFinite {
                    details.append(
                        .init(
                            "resets",
                            quota.expired
                                ? "Refresh to read the new window"
                                : "Resets in " + duration(reset.timeIntervalSince(now))))
                }
                if let tier = provider.grok?.tier { details.append(.init("account", tier)) }
                if let error = provider.error { details.append(.init("errors", error)) }
                rows.append(
                    .init(
                        provider.provider.rawValue + ":" + field,
                        source: provider.provider.rawValue,
                        title: provider.provider.label + " · " + title, value: quota.text,
                        icon: quota.expired
                            ? "clock.badge.exclamationmark"
                            : quota.percent == nil
                                ? "questionmark.circle" : "gauge.with.dots.needle.50percent",
                        progress: quota.fraction, field: field, details: details))
            }
        }
        return .init(
            metrics: [
                .init("providers", "Providers", "\(providers.count)"),
                .init(
                    "remaining", "Lowest remaining",
                    remaining.min().map { "\($0)%" } ?? "Unavailable"),
            ],
            rows: rows,
            message: snapshot.failure
                ?? (providers.isEmpty
                    ? "No providers match this widget. Connect a provider in Agent Usage or change the selection."
                    : nil),
            updatedAt: snapshot.refreshedAt,
            sources: snapshot.providers.map { .init($0.provider.rawValue, $0.provider.label) })
    }
    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(min(525_600, max(1, ceil(seconds / 60))))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
