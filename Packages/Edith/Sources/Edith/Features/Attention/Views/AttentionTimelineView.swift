import Charts
import EdithKit
import SwiftUI

struct AttentionTimelineView: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout
    @State private var selectedTimestamp: Date?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            dateStrip
            controls
            AttentionPanel(
                title: AttentionTime.day(store.selectedDate),
                subtitle: "Context, presence, media, intent, and automation on one clock"
            ) {
                timelineChart
            }
            if compactLayout {
                activityList
                inspector
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    activityList.frame(maxWidth: .infinity)
                    inspector.frame(width: UIScale.pt(290))
                }
            }
        }
        .sheet(isPresented: $store.showCorrection) {
            AttentionCorrectionSheet(store: store)
        }
    }

    private var dateStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(6)) {
                ForEach(store.allDates, id: \.self) { date in
                    let selected = store.calendar.isDate(date, inSameDayAs: store.selectedDate)
                    Button {
                        store.selectDate(date)
                    } label: {
                        VStack(spacing: UIScale.pt(3)) {
                            Text(date.formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: UIScale.pt(9), weight: .medium))
                            Text(date.formatted(.dateTime.day()))
                                .font(DashSkin.mono(11, weight: .semibold))
                        }
                        .foregroundStyle(selected ? Color.white : DashSkin.inkSoft(dark))
                        .frame(width: UIScale.pt(34), height: UIScale.pt(42))
                        .background(
                            selected ? DashSkin.accentDeep(dark) : DashSkin.paper2(dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(9))
                        )
                        .overlay {
                            if !selected {
                                RoundedRectangle(cornerRadius: UIScale.pt(9))
                                    .strokeBorder(DashSkin.line(dark))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.vertical, UIScale.pt(1))
        }
    }

    private var controls: some View {
        HStack(spacing: UIScale.pt(10)) {
            Picker("Activity", selection: $store.timelineFilter) {
                ForEach(["All activity", "Focus only", "Entertainment", "Uncertain"], id: \.self) {
                    Text($0)
                }
            }
            .labelsHidden()
            .frame(width: UIScale.pt(150))
            Text("\(store.daySegments.count) context events")
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            AttentionBadge(text: "96% HIGH CONFIDENCE", color: DashSkin.sage)
        }
    }

    private var filteredSegments: [AttentionSegment] {
        switch store.timelineFilter {
        case "Focus only": store.daySegments.filter { $0.focusSession != nil }
        case "Entertainment":
            store.daySegments.filter {
                store.category(for: $0.categoryID)?.kind == .entertainment
                    || store.category(for: $0.categoryID)?.kind == .distracting
            }
        case "Uncertain": store.daySegments.filter { $0.presence == .uncertain }
        default: store.daySegments
        }
    }

    private var timelineChart: some View {
        Chart {
            ForEach(filteredSegments) { segment in
                RectangleMark(
                    xStart: .value("Start", segment.start),
                    xEnd: .value("End", segment.end),
                    y: .value("Lane", "Context")
                )
                .foregroundStyle(AttentionPalette.category(segment.categoryID, dark: dark))
                .cornerRadius(3)
                RectangleMark(
                    xStart: .value("Start", segment.start),
                    xEnd: .value("End", segment.end),
                    y: .value("Lane", "Presence")
                )
                .foregroundStyle(AttentionPalette.presence(segment.presence, dark: dark))
                .cornerRadius(3)
                if segment.focusSession != nil {
                    RectangleMark(
                        xStart: .value("Start", segment.start),
                        xEnd: .value("End", segment.end),
                        y: .value("Lane", "Focus")
                    )
                    .foregroundStyle(DashSkin.sage)
                    .cornerRadius(3)
                }
                if segment.automation != nil {
                    RectangleMark(
                        xStart: .value("Start", segment.start),
                        xEnd: .value("End", segment.end),
                        y: .value("Lane", "Automation")
                    )
                    .foregroundStyle(Color.purple)
                    .cornerRadius(3)
                }
            }
            ForEach(
                store.mediaSessions.filter {
                    store.calendar.isDate($0.start, inSameDayAs: store.selectedDate)
                }
            ) { session in
                RectangleMark(
                    xStart: .value("Start", session.start),
                    xEnd: .value("End", session.end),
                    y: .value("Lane", "Media")
                )
                .foregroundStyle(Color.pink)
                .cornerRadius(3)
            }
            if let selectedTimestamp {
                RuleMark(x: .value("Selected", selectedTimestamp))
                    .foregroundStyle(DashSkin.ink(dark).opacity(0.35))
            }
        }
        .chartXScale(domain: dayDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                AxisGridLine().foregroundStyle(DashSkin.line(dark).opacity(0.55))
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(size: UIScale.pt(9)))
            }
        }
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel().font(.system(size: UIScale.pt(9.5))) }
        }
        .chartXSelection(value: $selectedTimestamp)
        .frame(height: UIScale.pt(220))
        .onChange(of: selectedTimestamp) { _, date in
            guard let date,
                let segment = filteredSegments.first(where: { $0.start <= date && $0.end >= date })
            else { return }
            store.selectSegment(segment)
        }
    }

    private var dayDomain: ClosedRange<Date> {
        let start = store.calendar.date(
            bySettingHour: 8, minute: 0, second: 0, of: store.selectedDate)!
        let end = store.calendar.date(
            bySettingHour: 23, minute: 30, second: 0, of: store.selectedDate)!
        return start...end
    }

    private var activityList: some View {
        AttentionPanel(title: "Activity", subtitle: "Select an interval to inspect or correct") {
            LazyVStack(spacing: 0) {
                ForEach(filteredSegments) { segment in
                    segmentRow(segment)
                    if segment.id != filteredSegments.last?.id {
                        Divider().overlay(DashSkin.line(dark).opacity(0.6))
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: AttentionSegment) -> some View {
        let selected = store.selectedSegmentID == segment.id
        return Button {
            store.selectSegment(segment)
        } label: {
            HStack(spacing: UIScale.pt(10)) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AttentionPalette.category(segment.categoryID, dark: dark))
                    .frame(width: UIScale.pt(4), height: UIScale.pt(32))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text(segment.service)
                            .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                        if segment.surface == .web {
                            Text(segment.profile ?? "Web")
                                .font(.system(size: UIScale.pt(8.5), weight: .semibold))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                    Text(segment.title)
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: UIScale.pt(3)) {
                    Text(AttentionTime.duration(segment.duration, compact: true))
                        .font(DashSkin.mono(10, weight: .semibold))
                    Text(
                        "\(AttentionTime.clock(segment.start)) - \(AttentionTime.clock(segment.end))"
                    )
                    .font(.system(size: UIScale.pt(8.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .foregroundStyle(DashSkin.ink(dark))
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(8))
            .background(
                selected ? DashSkin.accent(dark).opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(8))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var inspector: some View {
        if let segment = store.selectedSegment {
            AttentionPanel(title: "Interval details", subtitle: "Why Edith classified this") {
                VStack(alignment: .leading, spacing: UIScale.pt(13)) {
                    HStack(spacing: UIScale.pt(10)) {
                        Image(systemName: segment.presence.symbol)
                            .foregroundStyle(
                                AttentionPalette.presence(segment.presence, dark: dark)
                            )
                            .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                            .background(
                                AttentionPalette.presence(segment.presence, dark: dark).opacity(
                                    0.12),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(segment.service)
                                .font(.system(size: UIScale.pt(12), weight: .semibold))
                            Text(segment.presence.title)
                                .font(.system(size: UIScale.pt(10)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                    }
                    inspectorRow("Application", segment.application)
                    inspectorRow("Surface", surfaceLabel(segment))
                    inspectorRow(
                        "Category", store.category(for: segment.categoryID)?.path ?? "Uncategorized"
                    )
                    inspectorRow("Confidence", "\(Int(segment.confidence * 100))%")
                    if let focus = segment.focusSession { inspectorRow("Focus", focus) }
                    if let automation = segment.automation {
                        inspectorRow("Automation", automation)
                    }
                    Text(explanation(segment))
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .padding(UIScale.pt(10))
                        .background(
                            DashSkin.grid(dark).opacity(0.55),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                    Button("Correct this interval") { store.showCorrection = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .pointerCursor()
                }
            }
        } else {
            AttentionPanel(title: "Interval details") {
                Text("Select an interval from the timeline.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: UIScale.pt(9.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            Text(value)
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .multilineTextAlignment(.trailing)
        }
    }

    private func surfaceLabel(_ segment: AttentionSegment) -> String {
        if let browser = segment.browser, let profile = segment.profile {
            return "\(browser), \(profile)"
        }
        return segment.surface.title
    }

    private func explanation(_ segment: AttentionSegment) -> String {
        switch segment.presence {
        case .active: "Recent input and a foreground context change confirm interactive presence."
        case .passive:
            "Video progress and audio continued while the active display had no recent input."
        case .away: "The Mac was locked, asleep, or past the configured idle threshold."
        case .uncertain:
            "Playback continued without enough presence evidence. Edith keeps this separate until corrected."
        }
    }
}

private struct AttentionCorrectionSheet: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.dismiss) private var dismiss
    @State private var presence: AttentionPresence = .active
    @State private var categoryID = "work-coding"

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text("Correct interval").font(DashSkin.serif(24))
            if let segment = store.selectedSegment {
                Text(
                    "\(segment.service), \(AttentionTime.clock(segment.start)) to \(AttentionTime.clock(segment.end))"
                )
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.secondary)
            }
            Picker("Presence", selection: $presence) {
                ForEach(AttentionPresence.allCases) { state in Text(state.title).tag(state) }
            }
            Picker("Category", selection: $categoryID) {
                ForEach(store.categories) { category in Text(category.path).tag(category.id) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save correction") {
                    store.correctSelectedSegment(presence: presence, categoryID: categoryID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(UIScale.pt(24))
        .frame(width: UIScale.pt(430))
        .onAppear {
            guard let segment = store.selectedSegment else { return }
            presence = segment.presence
            categoryID = segment.categoryID
        }
    }
}
