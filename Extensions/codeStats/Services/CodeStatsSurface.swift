import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class CodeStatsSurface {
    private let store: CodeStatsStore
    private let workflow: CodeStatsWorkflow
    private let open: @MainActor () -> Void
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let privacy: @MainActor () -> [String: String]

    init(
        store: CodeStatsStore, workflow: CodeStatsWorkflow,
        open: @escaping @MainActor () -> Void = { ExtensionPresentation.showWindow() },
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
        privacy: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.store = store; self.workflow = workflow; self.open = open
        self.now = now; self.calendar = calendar; self.privacy = privacy
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        try await SurfaceCommandService.execute(
            providerID: "codeStats", command: command, payload: payload,
            snapshot: { [weak self] tile in
                guard let self else { throw ExtensionPeerError.unavailable }
                return try await self.snapshot(tile)
            },
            perform: { [weak self] action in
                guard let self else { throw ExtensionPeerError.unavailable }
                if action == "refresh" {
                    _ = try await self.workflow.start(.manual)
                } else if action == "open" || action.hasPrefix("day:") {
                    self.open()
                } else {
                    throw ExtensionPeerError.invalidRequest
                }
            }, privacyValues: privacy)
    }

    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        if SurfacePrivacyState.hides(tile.widget, values: privacy()) {
            return .init(providerID: "codeStats", message: "Hidden while presenting.")
        }
        let store = store; let now = now(); let calendar = calendar
        let value = await BlockingWork.value {
            () -> (CodeStatsFactTable, CodeStatsReport, CodeStatsReport)? in
            guard let table = store.loadFacts() else { return nil }
            var filter = CodeStatsFilter.default
            if let sources = tile.sourceIDs {
                filter.repositories = sources.intersection(Set(table.repositories))
                if filter.repositories.isEmpty {
                    return (
                        table,
                        CodeStatsReportBuilder.build(
                            table: .init(), filter: .default, range: .days(tile.days), today: now,
                            calendar: calendar),
                        CodeStatsReportBuilder.build(
                            table: .init(), filter: .default, range: .days(126), today: now,
                            calendar: calendar)
                    )
                }
            }
            return (
                table,
                CodeStatsReportBuilder.build(
                    table: table, filter: filter, range: .days(tile.days), today: now,
                    calendar: calendar),
                CodeStatsReportBuilder.build(
                    table: table, filter: filter, range: .days(126), today: now, calendar: calendar)
            )
        }
        try Task.checkCancellation()
        guard let (table, report, history) = value else {
            return .init(
                providerID: "codeStats",
                actions: [.init("open", "Open Code Stats", "arrow.up.right.square")],
                message: "No code statistics yet. Choose a mirror folder and refresh Code Stats.")
        }
        let totals = report.totals
        let metrics: [SurfaceMetric] = [
            .init("commits", "Commits", CodeStatsNumberFormat.grouped(totals.commits)),
            .init("lines", "Lines", CodeStatsNumberFormat.compact(totals.authored)),
            .init("streak", "Streak", "\(totals.currentStreak)d"),
            .init("activeDays", "Active days", CodeStatsNumberFormat.grouped(totals.activeDays)),
            .init("net", "Net lines", CodeStatsNumberFormat.compact(totals.net)),
        ]
        let rows = report.repositories.prefix(tile.itemLimit).map { repository in
            SurfaceDataRow(
                "repository:" + digest(repository.repository), sourceID: repository.repository,
                title: repository.repository,
                detail: tile.shows("languages") ? repository.topLanguage ?? "" : "",
                value: "\(CodeStatsNumberFormat.grouped(repository.commits)) commits",
                icon: "arrow.triangle.branch", field: "repositories")
        }
        let projection = CodeStatsProjection(report: history, calendar: calendar)
        let days = projection.heatWeeks.flatMap(\.cells).compactMap { cell -> SurfaceCalendarDay? in
            guard let date = cell.date else { return nil }
            let day = CodeStatsDay(date: date, calendar: calendar).string
            return .init(
                day, date: day, level: cell.level,
                value:
                    "\(CodeStatsNumberFormat.grouped(cell.commits)) commits, \(CodeStatsNumberFormat.compact(cell.lines)) lines",
                action: .init("day:" + day, "Open Code Stats", "calendar"))
        }
        let points = report.daily.suffix(366).compactMap { day -> SurfaceChartPoint? in
            guard let date = SurfaceCalendarDay.parse(day.day) else { return nil }
            return .init(
                day.day, x: date.timeIntervalSince1970, y: Double(day.commits), label: day.day,
                value: "\(day.commits) commits")
        }
        return .init(
            providerID: "codeStats", metrics: metrics, rows: rows,
            actions: [
                .init("open", "Open Code Stats", "arrow.up.right.square"),
                .init("refresh", "Refresh", "arrow.clockwise"),
            ],
            charts: points.isEmpty
                ? []
                : [
                    .init(
                        "commits", "Daily commits",
                        series: [.init("commits", "Commits", points: points)], xAxis: .date,
                        xTitle: "Day", yTitle: "Commits")
                ],
            calendars: days.isEmpty ? [] : [.init("activity", "Code activity", days: days)],
            sources: table.repositories.prefix(100).map { .init($0, $0) },
            updatedAt: store.loadState().reportedAt)
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
