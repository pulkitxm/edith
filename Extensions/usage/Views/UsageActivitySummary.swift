import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct UsageActivitySummary: Equatable {
    var busiestDate: Date?
    var busiestTokens = 0.0
    var averageTokens = 0.0
    var activeDays = 0
    var streak = 0

    static func make(
        days: [DayPoint], today: Date = Date(), calendar: Calendar = .current
    ) -> UsageActivitySummary {
        let active = days.filter { $0.tokens > 0 }
        guard !active.isEmpty else { return UsageActivitySummary() }
        let busiest = active.max { $0.tokens < $1.tokens }
        let activeDates = Set(active.map { calendar.startOfDay(for: $0.date) })
        var cursor = calendar.startOfDay(for: today)
        if !activeDates.contains(cursor),
            let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor)
        {
            cursor = yesterday
        }
        var streak = 0
        while activeDates.contains(cursor),
            let previous = calendar.date(byAdding: .day, value: -1, to: cursor)
        {
            streak += 1
            cursor = previous
        }
        return UsageActivitySummary(
            busiestDate: busiest?.date, busiestTokens: busiest?.tokens ?? 0,
            averageTokens: active.reduce(0) { $0 + $1.tokens } / Double(active.count),
            activeDays: active.count, streak: streak)
    }
}

struct UsageActivitySummaryView: View {
    let summary: UsageActivitySummary
    let axis: Axis
    var blurTokens = false

    private static let dayFormat = Date.FormatStyle().weekday(.abbreviated).day().month(
        .abbreviated)

    var body: some View {
        let layout =
            axis == .vertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(16)))
            : AnyLayout(HStackLayout(alignment: .top, spacing: UIScale.pt(16)))
        layout {
            stat(
                "Busiest day", value: DashFmt.tokens(summary.busiestTokens),
                detail: summary.busiestDate.map { $0.formatted(Self.dayFormat) } ?? "No usage yet",
                blur: blurTokens)
            stat(
                "Daily average", value: DashFmt.tokens(summary.averageTokens),
                detail: "tokens per active day", blur: blurTokens)
            stat(
                "Current streak", value: summary.streak == 1 ? "1 day" : "\(summary.streak) days",
                detail: summary.streak == 0 ? "No usage yesterday or today" : "in a row with usage",
                blur: false)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func stat(_ label: String, value: String, detail: String, blur: Bool) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            PageCapsLabel(label)
            Text(value)
                .font(.edithText(.title3).weight(.semibold))
                .monospacedDigit()
                .presenterBlur(blur)
            Text(detail)
                .font(.edithText(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: axis == .horizontal ? .infinity : nil, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
