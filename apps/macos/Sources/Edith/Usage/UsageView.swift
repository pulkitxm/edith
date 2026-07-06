import EdithKit
import SwiftUI

struct UsageView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var showLog = false
    @State private var showDiagnostics = false
    @AppStorage("presenterMode") private var presenter = false
    @AppStorage("presenterBlurMoney") private var presenterBlurMoney = true
    @AppStorage("theme") private var themeName = "accent"

    private var theme: Color { themeColor(themeName) }
    private var blurMoney: Bool { presenter && presenterBlurMoney }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            limitsCard
            if !store.calendarDays.isEmpty {
                activityCard
            }
            usageCard
        }
        .task {
            await store.loadStats()
            await store.loadLimitHistory()
        }
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                eyebrow("LIMITS")
                Spacer()
                if let at = store.limitsUpdatedAt {
                    let next =
                        store.nextLimitsRefresh
                        .map { $0.formatted(date: .omitted, time: .shortened) } ?? "-"
                    Text("updated \(at.formatted(date: .omitted, time: .shortened)) · next \(next)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showDiagnostics.toggle() }
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(showDiagnostics ? theme : Color.secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Show diagnostic log")
                Button {
                    Task { await store.refreshLimits(force: true) }
                } label: {
                    Group {
                        if store.refreshingLimits {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(HoverButtonStyle())
                .disabled(store.refreshingLimits)
                .help("Refresh limits now")
            }
            HStack(spacing: 12) {
                ring("SESSION", window: store.session)
                ring("WEEK", window: store.week)
            }
            if !store.limitPoints.isEmpty {
                LimitsChartView(points: store.limitPoints, theme: theme)
                    .padding(.top, 2)
            } else {
                Text("Collecting limits history - chart appears after a few polls")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if let err = store.limitsError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if showDiagnostics {
                TerminalLogView(log: store.diagnostics, theme: theme, height: 130)
            }
        }
        .card()
    }

    private func ring(_ label: String, window: LimitWindow?) -> some View {
        let pct = window?.percent ?? 0
        let fill = color(for: pct)
        return VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.1), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(pct / 100, 1))
                    .stroke(fill, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: pct)
                Text(window != nil ? "\(Int(pct))%" : "-")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 88, height: 88)
            .padding(.bottom, 2)
            eyebrow(label)
            if let reset = window?.resetsAt, reset > Date() {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(countdown(from: context.date, to: reset))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text(" ").font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func countdown(from now: Date, to reset: Date) -> String {
        let s = max(0, Int(reset.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: "%dd %d:%02d:%02d", d, h, m, sec) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func color(for percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : theme
    }

    private var activityCard: some View {
        let days = store.calendarDays
        let weeks: [[DayPoint]] = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
        let nonzero = days.map(\.cost).filter { $0 > 0 }.sorted()
        let quartile = { (p: Double) -> Double in
            nonzero.isEmpty ? 0 : nonzero[Int(Double(nonzero.count - 1) * p)]
        }
        let cuts = [quartile(0.25), quartile(0.5), quartile(0.75)]
        let total = days.reduce(0) { $0 + $1.cost }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                eyebrow("ACTIVITY")
                Spacer()
                Text(String(format: "$%.0f · %d weeks", total, weeks.count))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .presenterBlur(blurMoney)
            }
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    ForEach(Array(["M", "", "W", "", "F", "", "S"].enumerated()), id: \.offset) {
                        _, label in
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(width: 13, height: 17)
                    }
                }
                .padding(.top, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                            VStack(spacing: 4) {
                                Text(monthLabel(for: weeks, at: index))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .frame(height: 12)
                                ForEach(week) { day in
                                    RoundedRectangle(cornerRadius: 3.5)
                                        .fill(cellColor(day.cost, cuts: cuts))
                                        .frame(width: 17, height: 17)
                                        .help(
                                            blurMoney
                                                ? day.date.formatted(.dateTime.day().month())
                                                : "\(day.date.formatted(.dateTime.day().month())) - $\(String(format: "%.2f", day.cost))"
                                        )
                                }
                            }
                        }
                    }
                }
                .defaultScrollAnchor(weeks.count > 19 ? .trailing : .leading)
            }
        }
        .card()
    }

    private func monthLabel(for weeks: [[DayPoint]], at index: Int) -> String {
        guard let first = weeks[index].first?.date else { return "" }
        let month = Calendar.current.component(.month, from: first)
        if index > 0, let prev = weeks[index - 1].first?.date,
            Calendar.current.component(.month, from: prev) == month
        {
            return ""
        }
        return first.formatted(.dateTime.month(.abbreviated))
    }

    private func cellColor(_ cost: Double, cuts: [Double]) -> Color {
        if cost <= 0 { return .primary.opacity(0.08) }
        if cost <= cuts[0] { return theme.opacity(0.25) }
        if cost <= cuts[1] { return theme.opacity(0.45) }
        if cost <= cuts[2] { return theme.opacity(0.7) }
        return theme
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                eyebrow("USAGE")
                Spacer()
                Button {
                    store.runUpdate()
                } label: {
                    Group {
                        if store.updating {
                            ProgressView().progressViewStyle(.circular).controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(.secondary)
                .disabled(store.updating)
                .help("Refresh usage data")
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() }
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(showLog ? theme : Color.secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Show refresh log")
                Button {
                    DashboardWindow.open(store: store)
                    dismissPanel()
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(.secondary)
                .help("Open the full dashboard")
            }
            .font(.system(size: 13))

            HStack {
                sourcePicker
                Spacer()
                if let at = store.statsGeneratedAt {
                    Text("Data from \(at.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if showLog {
                logView
            }

            if let err = store.statsError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                VStack(spacing: 9) {
                    ForEach(store.stats) { stat in
                        HStack {
                            Text(stat.label)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(stat.tokens.compactTokens)
                                .monospacedDigit()
                                .presenterBlur(blurMoney)
                            Text(String(format: "$%.2f", stat.cost))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .trailing)
                                .presenterBlur(blurMoney)
                        }
                        .font(.system(size: 13))
                    }
                }
            }
        }
        .card()
    }

    private var sourcePicker: some View {
        Menu {
            ForEach(store.sources) { source in
                Button {
                    if store.selectedSources.contains(source.id) {
                        if store.selectedSources.count > 1 {
                            store.selectedSources.remove(source.id)
                        }
                    } else {
                        store.selectedSources.insert(source.id)
                    }
                } label: {
                    HStack {
                        if store.selectedSources.contains(source.id) {
                            Image(systemName: "checkmark")
                        }
                        Text(source.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(sourceSummary)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .hoverButton()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sourceSummary: String {
        let picked = store.sources.filter { store.selectedSources.contains($0.id) }
        if picked.count == store.sources.count, !picked.isEmpty { return "All sources" }
        guard let first = picked.first else { return "Sources" }
        return picked.count == 1 ? first.label : "\(first.label) +\(picked.count - 1)"
    }

    private var logView: some View {
        TerminalLogView(log: store.log, theme: theme, height: 130)
    }
}

extension Double {
    var compactTokens: String {
        switch self {
        case 1e9...: return String(format: "%.2fB", self / 1e9)
        case 1e6...: return String(format: "%.1fM", self / 1e6)
        case 1e3...: return String(format: "%.1fK", self / 1e3)
        default: return String(format: "%.0f", self)
        }
    }
}
