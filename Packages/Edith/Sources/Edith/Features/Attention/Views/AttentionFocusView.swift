import Charts
import EdithKit
import SwiftUI

struct AttentionFocusView: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            sessionHero
            templateGrid
            if compactLayout {
                sessionHistory
                focusTrend
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    sessionHistory.frame(maxWidth: .infinity)
                    focusTrend.frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $store.showFocusBuilder) {
            AttentionFocusBuilder(store: store)
        }
    }

    private var activeTemplate: AttentionFocusTemplate? {
        guard let id = store.activeFocusTemplateID else { return nil }
        return store.focusTemplates.first { $0.id == id }
    }

    @ViewBuilder
    private var sessionHero: some View {
        if let template = activeTemplate {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(store.focusStartedAt ?? context.date))
                HStack(spacing: UIScale.pt(18)) {
                    ZStack {
                        Circle().stroke(DashSkin.line(dark), lineWidth: UIScale.pt(7))
                        Circle()
                            .trim(from: 0, to: template.durationMinutes.map { min(1, elapsed / Double($0 * 60)) } ?? 0.72)
                            .stroke(DashSkin.accentDeep(dark), style: StrokeStyle(lineWidth: UIScale.pt(7), lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: template.symbol)
                            .font(.system(size: UIScale.pt(24), weight: .medium))
                            .foregroundStyle(DashSkin.accentDeep(dark))
                    }
                    .frame(width: UIScale.pt(82), height: UIScale.pt(82))
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        AttentionBadge(text: "FOCUS ACTIVE", color: DashSkin.sage)
                        Text(template.name)
                            .font(DashSkin.serif(26))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text(AttentionTime.duration(elapsed, compact: true) + " elapsed")
                            .font(DashSkin.mono(11, weight: .semibold))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: UIScale.pt(8)) {
                        Text("\(template.intervention) after \(template.graceSeconds)s off-intent")
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Button("End session") { store.endFocus() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .pointerCursor()
                    }
                }
                .padding(UIScale.pt(18))
                .widgetBar(cornerRadius: 16, fill: DashSkin.paper2(dark), stroke: DashSkin.accent(dark).opacity(0.32), shadow: .black.opacity(dark ? 0.3 : 0.05))
            }
        } else {
            HStack(spacing: UIScale.pt(18)) {
                Image(systemName: "scope")
                    .font(.system(size: UIScale.pt(30), weight: .medium))
                    .foregroundStyle(DashSkin.accentDeep(dark))
                    .frame(width: UIScale.pt(74), height: UIScale.pt(74))
                    .background(DashSkin.accent(dark).opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    Text("Ready when you are")
                        .font(DashSkin.serif(26))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text("Choose a template below or configure a session around your current goal.")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
                Spacer()
                Button("Create focus session") { store.showFocusBuilder = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointerCursor()
            }
            .padding(UIScale.pt(18))
            .widgetBar(cornerRadius: 16, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark), shadow: .black.opacity(dark ? 0.3 : 0.05))
        }
    }

    private var templateGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: UIScale.pt(190)), spacing: UIScale.pt(10))],
            spacing: UIScale.pt(10)
        ) {
            ForEach(store.focusTemplates) { template in
                Button {
                    store.beginFocus(template.id)
                } label: {
                    VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                        HStack {
                            Image(systemName: template.symbol)
                                .foregroundStyle(DashSkin.accentDeep(dark))
                            Spacer()
                            Text(template.durationMinutes.map { "\($0)m" } ?? "Open")
                                .font(DashSkin.mono(9.5, weight: .semibold))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        Text(template.name)
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text("\(template.allowedCategoryIDs.count) allowed categories · \(template.intervention)")
                            .font(.system(size: UIScale.pt(9.5)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                    .padding(UIScale.pt(13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetBar(cornerRadius: 13, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark), shadow: .clear)
                }
                .buttonStyle(.plain)
                .disabled(activeTemplate != nil)
                .pointerCursor()
            }
        }
    }

    private var sessionHistory: some View {
        AttentionPanel(title: "Recent sessions", subtitle: "Intentional work, interruptions, and delegated runtime") {
            VStack(spacing: 0) {
                ForEach(Array(store.visibleFocusSessions.suffix(8).reversed())) { session in
                    HStack(spacing: UIScale.pt(10)) {
                        Circle()
                            .trim(from: 0, to: session.focusRatio)
                            .stroke(DashSkin.sage, style: StrokeStyle(lineWidth: UIScale.pt(4), lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                            .overlay(Text("\(Int(session.focusRatio * 100))").font(.system(size: UIScale.pt(7), weight: .bold)))
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(session.name).font(.system(size: UIScale.pt(10.5), weight: .semibold))
                            Text(AttentionTime.day(session.start) + " · " + AttentionTime.duration(session.duration, compact: true))
                                .font(.system(size: UIScale.pt(8.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        Spacer()
                        Text("\(session.interruptions) interruptions")
                            .font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                    .padding(.vertical, UIScale.pt(8))
                    Divider().overlay(DashSkin.line(dark).opacity(0.55))
                }
            }
        }
    }

    private var focusTrend: some View {
        AttentionPanel(title: "Focus quality", subtitle: "Transparent daily ratio, not a hidden score") {
            Chart(store.dailySummaries) { summary in
                LineMark(
                    x: .value("Date", summary.date, unit: .day),
                    y: .value("Ratio", ratio(summary)))
                    .foregroundStyle(DashSkin.sage)
                    .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value("Date", summary.date, unit: .day),
                    y: .value("Ratio", ratio(summary)))
                    .foregroundStyle(DashSkin.sage.opacity(0.12))
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0.4...1)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.5, 0.75, 1]) { value in
                    AxisGridLine().foregroundStyle(DashSkin.line(dark))
                    AxisValueLabel {
                        if let ratio = value.as(Double.self) { Text("\(Int(ratio * 100))%") }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: store.selectedRange == .month ? 6 : 1)) {
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .font(.system(size: UIScale.pt(9)))
            .frame(height: UIScale.pt(220))
        }
    }

    private func ratio(_ summary: AttentionDailySummary) -> Double {
        let relevant = summary.focusSeconds + summary.distractingSeconds
        return relevant > 0 ? summary.focusSeconds / relevant : 0.7
    }
}

private struct AttentionFocusBuilder: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.dismiss) private var dismiss
    @State private var templateID = "flow"
    @State private var goal = "Finish the Attention prototype"
    @State private var intervention = "Nudge"

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            Text("Create focus session").font(DashSkin.serif(24))
            TextField("Goal", text: $goal)
            Picker("Template", selection: $templateID) {
                ForEach(store.focusTemplates) { template in Text(template.name).tag(template.id) }
            }
            Picker("When I drift", selection: $intervention) {
                ForEach(["Observe", "Nudge", "Block"], id: \.self) { Text($0) }
            }
            Toggle("Allow background music", isOn: .constant(true))
            Toggle("Track delegated work separately", isOn: .constant(true))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start focus") {
                    store.beginFocus(templateID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(UIScale.pt(24))
        .frame(width: UIScale.pt(460))
    }
}
