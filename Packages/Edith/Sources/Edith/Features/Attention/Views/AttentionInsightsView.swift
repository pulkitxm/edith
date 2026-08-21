import Charts
import EdithKit
import SwiftUI

struct AttentionInsightsView: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout

    private var dark: Bool { scheme == .dark }
    private var filters: [String] {
        ["Highlights", "Focus", "Attention", "Distraction", "Music", "Automation", "Quality"]
    }
    private var filteredInsights: [AttentionInsight] {
        guard store.insightFilter != "Highlights" else { return store.insights }
        return store.insights.filter { $0.category == store.insightFilter }
    }
    private var selectedInsight: AttentionInsight? {
        store.insights.first { $0.id == store.selectedInsightID } ?? filteredInsights.first
    }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            filterBar
            if compactLayout {
                insightList
                insightDetail
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    insightList.frame(maxWidth: .infinity)
                    insightDetail.frame(width: UIScale.pt(330))
                }
            }
            trendPanel
        }
        .onAppear {
            if store.selectedInsightID == nil { store.selectedInsightID = filteredInsights.first?.id }
        }
    }

    private var filterBar: some View {
        HStack(spacing: UIScale.pt(6)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(5)) {
                    ForEach(filters, id: \.self) { filter in
                        Button(filter) {
                            store.insightFilter = filter
                            store.selectedInsightID = filteredInsights.first?.id
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                        .foregroundStyle(
                            store.insightFilter == filter ? Color.white : DashSkin.inkSoft(dark))
                        .padding(.horizontal, UIScale.pt(10))
                        .frame(height: UIScale.pt(27))
                        .background(
                            store.insightFilter == filter ? DashSkin.accentDeep(dark) : DashSkin.paper2(dark),
                            in: Capsule())
                        .overlay {
                            if store.insightFilter != filter {
                                Capsule().strokeBorder(DashSkin.line(dark))
                            }
                        }
                        .pointerCursor()
                    }
                }
            }
            Spacer()
            AttentionBadge(text: "LOCAL ANALYSIS", color: DashSkin.sage)
        }
    }

    private var insightList: some View {
        AttentionPanel(title: "What changed", subtitle: "Deterministic insights with confidence and evidence") {
            VStack(spacing: UIScale.pt(8)) {
                ForEach(filteredInsights) { insight in
                    insightButton(insight)
                }
            }
        }
    }

    private func insightButton(_ insight: AttentionInsight) -> some View {
        let selected = selectedInsight?.id == insight.id
        return Button {
            store.selectedInsightID = insight.id
        } label: {
            HStack(alignment: .top, spacing: UIScale.pt(11)) {
                Image(systemName: insight.symbol)
                    .foregroundStyle(selected ? Color.white : DashSkin.accentDeep(dark))
                    .frame(width: UIScale.pt(30), height: UIScale.pt(30))
                    .background(
                        selected ? DashSkin.accentDeep(dark) : DashSkin.accent(dark).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(insight.title)
                            .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                        Spacer()
                        Text(insight.value)
                            .font(DashSkin.mono(10, weight: .semibold))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                    Text(insight.detail)
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(2)
                }
            }
            .padding(UIScale.pt(9))
            .background(
                selected ? DashSkin.accent(dark).opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: UIScale.pt(10))
                        .strokeBorder(DashSkin.accent(dark).opacity(0.18))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var insightDetail: some View {
        if let insight = selectedInsight {
            AttentionPanel(title: "Evidence", subtitle: insight.category) {
                VStack(alignment: .leading, spacing: UIScale.pt(15)) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(insight.value)
                            .font(DashSkin.serif(30))
                            .foregroundStyle(DashSkin.ink(dark))
                        Spacer()
                        AttentionBadge(
                            text: "\(Int(insight.confidence * 100))% CONFIDENCE",
                            color: insight.confidence > 0.85 ? DashSkin.sage : DashSkin.warn)
                    }
                    Text(insight.detail)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    Divider().overlay(DashSkin.line(dark))
                    evidenceRow("Range", store.selectedRange.title)
                    evidenceRow("Days included", "\(store.visibleDates.count)")
                    evidenceRow("Context segments", "\(store.visibleSegments.count)")
                    evidenceRow("Listening sessions", "\(store.visibleMedia.count)")
                    evidenceRow("Focus sessions", "\(store.visibleFocusSessions.count)")
                    Text("This insight uses local aggregates. Open the timeline to inspect the underlying intervals.")
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(UIScale.pt(10))
                        .background(DashSkin.grid(dark).opacity(0.5), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                    Button("Inspect on timeline") { store.selectedSection = .timeline }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .pointerCursor()
                }
            }
        }
    }

    private func evidenceRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: UIScale.pt(10)))
    }

    private var trendPanel: some View {
        AttentionPanel(
            title: "Focus and fragmentation",
            subtitle: "Daily intentional hours and meaningful context switches"
        ) {
            Chart(store.dailySummaries) { summary in
                BarMark(
                    x: .value("Date", summary.date, unit: .day),
                    y: .value("Focus hours", summary.focusSeconds / 3600))
                    .foregroundStyle(DashSkin.sage.opacity(0.72))
                    .cornerRadius(2)
                LineMark(
                    x: .value("Date", summary.date, unit: .day),
                    y: .value("Switches", Double(summary.switches) / 4))
                    .foregroundStyle(DashSkin.accentDeep(dark))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1.5)))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: store.selectedRange == .month ? 5 : 1)) {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .font(.system(size: UIScale.pt(9)))
                    AxisGridLine().foregroundStyle(DashSkin.line(dark).opacity(0.35))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(DashSkin.line(dark).opacity(0.5))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text("\(Int(number))h").font(.system(size: UIScale.pt(9)))
                        }
                    }
                }
            }
            .frame(height: UIScale.pt(210))
        }
    }
}
