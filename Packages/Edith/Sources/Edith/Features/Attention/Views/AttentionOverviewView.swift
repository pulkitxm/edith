import Charts
import EdithKit
import SwiftUI

private struct AttentionServiceTotal {
    let identity: AttentionIdentity
    let seconds: TimeInterval
}

struct AttentionOverviewView: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout
    @State private var chartSelection: Date?

    private var dark: Bool { scheme == .dark }
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: UIScale.pt(10)), count: compactLayout ? 2 : 4)
    }
    private var topServiceTotals: [AttentionServiceTotal] {
        let grouped = Dictionary(grouping: store.visibleSegments, by: \.service)
        return store.identities.compactMap { identity in
            let seconds = grouped[identity.name]?.reduce(0) { $0 + $1.duration } ?? 0
            guard seconds > 0 else { return nil }
            return AttentionServiceTotal(identity: identity, seconds: seconds)
        }
        .sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            LazyVGrid(columns: columns, spacing: UIScale.pt(10)) {
                ForEach(store.metrics) { metric in AttentionMetricCard(metric: metric) }
            }
            allocationPanel
            if compactLayout {
                topServices
                focusAndMedia
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    topServices
                    focusAndMedia
                }
            }
            insightStrip
        }
    }

    private var allocationPanel: some View {
        AttentionPanel(
            title: "Where your attention went",
            subtitle: rangeSubtitle,
            actionTitle: "Open timeline",
            action: { store.selectedSection = .timeline }
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(spacing: UIScale.pt(12)) {
                    AttentionLegendItem(title: "Intentional", color: DashSkin.sage)
                    AttentionLegendItem(title: "Distraction", color: DashSkin.danger)
                    AttentionLegendItem(title: "Entertainment", color: Color.indigo)
                    AttentionLegendItem(title: "Away", color: DashSkin.inkFaint(dark))
                }
                .lineLimit(1)
                Chart(store.dailySummaries) { summary in
                    BarMark(
                        x: .value("Date", summary.date, unit: .day),
                        y: .value("Hours", summary.focusSeconds / 3600)
                    )
                    .foregroundStyle(DashSkin.sage)
                    .cornerRadius(2)
                    BarMark(
                        x: .value("Date", summary.date, unit: .day),
                        y: .value("Hours", summary.distractingSeconds / 3600)
                    )
                    .foregroundStyle(DashSkin.danger)
                    .cornerRadius(2)
                    BarMark(
                        x: .value("Date", summary.date, unit: .day),
                        y: .value("Hours", summary.entertainmentSeconds / 3600)
                    )
                    .foregroundStyle(Color.indigo)
                    .cornerRadius(2)
                    BarMark(
                        x: .value("Date", summary.date, unit: .day),
                        y: .value("Hours", summary.awaySeconds / 3600)
                    )
                    .foregroundStyle(DashSkin.inkFaint(dark).opacity(0.6))
                    .cornerRadius(2)
                    if let chartSelection {
                        RuleMark(x: .value("Selected", chartSelection, unit: .day))
                            .foregroundStyle(DashSkin.ink(dark).opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXAxis {
                    AxisMarks(
                        values: .stride(
                            by: store.selectedRange == .month ? .day : .day,
                            count: store.selectedRange == .month ? 5 : 1)
                    ) { value in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .font(.system(size: UIScale.pt(9)))
                        AxisGridLine().foregroundStyle(DashSkin.line(dark).opacity(0.35))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(DashSkin.line(dark).opacity(0.55))
                        AxisValueLabel {
                            if let hours = value.as(Double.self) {
                                Text("\(Int(hours))h").font(.system(size: UIScale.pt(9)))
                            }
                        }
                    }
                }
                .chartXSelection(value: $chartSelection)
                .frame(height: UIScale.pt(210))
                .onChange(of: chartSelection) { _, date in
                    guard let date else { return }
                    store.selectDate(date)
                }
            }
        }
    }

    private var topServices: some View {
        AttentionPanel(
            title: "Top services", subtitle: "Native and web surfaces unified",
            actionTitle: "Manage",
            action: { store.selectedSection = .library }
        ) {
            VStack(spacing: 0) {
                ForEach(Array(topServiceTotals.prefix(6).enumerated()), id: \.element.identity.id) {
                    index, total in
                    Button {
                        store.selectedIdentityID = total.identity.id
                        store.selectedSection = .library
                    } label: {
                        HStack(spacing: UIScale.pt(10)) {
                            Text("\(index + 1)")
                                .font(DashSkin.mono(10, weight: .semibold))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .frame(width: UIScale.pt(18))
                            Image(systemName: total.identity.symbol)
                                .foregroundStyle(
                                    AttentionPalette.category(total.identity.categoryID, dark: dark)
                                )
                                .frame(width: UIScale.pt(20))
                            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                Text(total.identity.name)
                                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                Text(
                                    store.category(for: total.identity.categoryID)?.path
                                        ?? "Uncategorized"
                                )
                                .font(.system(size: UIScale.pt(9.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                            Spacer()
                            Text(AttentionTime.duration(total.seconds, compact: true))
                                .font(DashSkin.mono(10, weight: .medium))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                        .padding(.vertical, UIScale.pt(8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    if index < 5 { Divider().overlay(DashSkin.line(dark).opacity(0.6)) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var focusAndMedia: some View {
        AttentionPanel(
            title: "Concurrent activity", subtitle: "Never added to elapsed time"
        ) {
            VStack(spacing: UIScale.pt(15)) {
                concurrentRow(
                    symbol: "gearshape.2.fill", title: "Delegated work",
                    value: AttentionTime.duration(
                        store.dailySummaries.reduce(0) { $0 + $1.automationSeconds }, compact: true),
                    detail: "Agent runtime while your context moved elsewhere", color: Color.purple)
                Divider().overlay(DashSkin.line(dark))
                concurrentRow(
                    symbol: "music.note", title: "Listening time",
                    value: AttentionTime.duration(
                        store.dailySummaries.reduce(0) { $0 + $1.musicSeconds }, compact: true),
                    detail: "\(store.visibleMedia.count) exact playback sessions", color: Color.pink
                )
                Divider().overlay(DashSkin.line(dark))
                concurrentRow(
                    symbol: "play.rectangle.fill", title: "Passive video",
                    value: AttentionTime.duration(
                        store.dailySummaries.reduce(0) { $0 + $1.passiveSeconds }, compact: true),
                    detail: "Playback advancing with no recent input", color: Color.indigo)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func concurrentRow(
        symbol: String, title: String, value: String, detail: String, color: Color
    ) -> some View {
        HStack(spacing: UIScale.pt(11)) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: UIScale.pt(30), height: UIScale.pt(30))
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                HStack {
                    Text(title).font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    Spacer()
                    Text(value).font(DashSkin.mono(11, weight: .semibold))
                }
                Text(detail)
                    .font(.system(size: UIScale.pt(9.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
        }
    }

    private var insightStrip: some View {
        Button {
            store.selectedInsightID = store.insights.first?.id
            store.selectedSection = .insights
        } label: {
            HStack(spacing: UIScale.pt(12)) {
                Image(systemName: "sparkles")
                    .foregroundStyle(DashSkin.accentDeep(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(store.insights.first?.title ?? "Insights")
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(store.insights.first?.detail ?? "")
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(UIScale.pt(14))
            .background(
                DashSkin.accent(dark).opacity(0.08),
                in: RoundedRectangle(cornerRadius: UIScale.pt(14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(14)).strokeBorder(
                    DashSkin.accent(dark).opacity(0.2)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var rangeSubtitle: String {
        guard let first = store.visibleDates.first, let last = store.visibleDates.last else {
            return ""
        }
        if store.selectedRange == .day { return AttentionTime.day(last) }
        return
            "\(first.formatted(.dateTime.month(.abbreviated).day())) to \(last.formatted(.dateTime.month(.abbreviated).day()))"
    }
}
