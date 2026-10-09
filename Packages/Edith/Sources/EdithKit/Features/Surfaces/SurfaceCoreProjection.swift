import Foundation

public struct SurfaceQuotaValue: Equatable, Sendable {
    public let percent: Double?
    public let expired: Bool
    public var fraction: Double? { percent.map { $0 / 100 } }
    public var remaining: Int? { percent.map { max(0, 100 - Int($0.rounded())) } }
    public var text: String {
        if expired { return "Expired" }
        return percent.map { "\(Int($0.rounded()))% used" } ?? "Unavailable"
    }
    public init(_ window: LimitWindow?, now: Date = Date()) {
        expired = window?.resetsAt.map { $0.timeIntervalSince1970.isFinite && $0 <= now } ?? false
        guard let window, window.percent.isFinite, window.percent >= 0, !expired,
            window.resetsAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { percent = nil; return }
        percent = min(100, window.percent)
    }
}

public enum SurfaceCoreProjection {
    public static func limits(
        _ snapshot: LimitsTopicSnapshot, tile: SurfaceTile, now: Date = Date()
    ) -> SurfaceExtensionSnapshot {
        let providers = snapshot.providers.filter {
            tile.sourceIDs?.contains($0.provider.rawValue) ?? true
        }
        var rows: [SurfaceDataRow] = []
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
                let quota = SurfaceQuotaValue(window, now: now)
                if let capacity = quota.remaining { remaining.append(capacity) }
                var details: [SurfaceRowDetail] = []
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
            actions: [.init("Open Agent Usage", "arrow.up.right", .navigate("dashboard"))],
            message: snapshot.failure
                ?? (providers.isEmpty
                    ? "No providers match this widget. Connect a provider in Agent Usage or change the selection."
                    : nil),
            updatedAt: snapshot.refreshedAt,
            sources: snapshot.providers.map { .init($0.provider.rawValue, $0.provider.label) })
    }
    public static func codeStats(_ report: CodeStatsReport?, tile: SurfaceTile)
        -> SurfaceExtensionSnapshot
    {
        guard let report else {
            return .init(
                actions: [.init("Set up Code Stats", "arrow.up.right", .navigate("codeStats"))],
                message: "Set up your code stats mirror to see repository activity.")
        }
        let totals = report.totals
        return .init(
            metrics: [
                .init("commits", "Commits", "\(totals.commits)"),
                .init("lines", "Authored lines", CodeStatsNumberFormat.compact(totals.authored)),
                .init("streak", "Current streak", "\(totals.currentStreak)d"),
                .init("activeDays", "Active days", "\(totals.activeDays)"),
                .init("net", "Net lines", CodeStatsNumberFormat.compact(totals.net)),
            ],
            rows: report.repositories.map { repository in
                .init(
                    repository.repository, title: repository.repository,
                    value: "\(repository.commits) commits", icon: "curlybraces",
                    field: "repositories",
                    details: [
                        .init(
                            "lines",
                            CodeStatsNumberFormat.compact(repository.counts.authored)
                                + " authored lines"),
                        .init("languages", repository.topLanguage ?? ""),
                        .init("activeDays", "\(repository.activeDays) active days"),
                    ])
            }, actions: [.init("Open Code Stats", "arrow.up.right", .navigate("codeStats"))],
            message: "\(report.startDay) to \(report.endDay) · \(totals.repositories) repositories"
                + (tile.sourceIDs == nil ? "" : " · Selected repositories only"),
            sources: report.repositories.map { .init($0.repository, $0.repository) })
    }
    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(min(525_600, max(1, ceil(seconds / 60))))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
