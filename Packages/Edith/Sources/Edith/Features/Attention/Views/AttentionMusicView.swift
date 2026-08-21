import Charts
import EdithKit
import SwiftUI

private struct AttentionMusicAggregate: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let seconds: TimeInterval
    let sessions: Int
    let completion: Double
}

struct AttentionMusicView: View {
    @Bindable var store: AttentionMockStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout
    @State private var selectedMusicID: String?

    private var dark: Bool { scheme == .dark }
    private var aggregates: [AttentionMusicAggregate] {
        let grouped = Dictionary(grouping: store.visibleMedia) { session in
            switch store.musicGrouping {
            case "Artists": session.artist
            case "Albums": session.album
            case "Services": session.service
            default: session.track
            }
        }
        return grouped.map { key, sessions in
            let seconds = sessions.reduce(0) { $0 + $1.playedSeconds }
            let completion = sessions.reduce(0) { $0 + $1.completion } / Double(max(1, sessions.count))
            let first = sessions[0]
            let subtitle: String
            switch store.musicGrouping {
            case "Artists": subtitle = "\(sessions.count) listening sessions"
            case "Albums": subtitle = first.artist
            case "Services": subtitle = "Native and browser playback"
            default: subtitle = first.artist + " · " + first.album
            }
            return AttentionMusicAggregate(
                id: key, title: key, subtitle: subtitle, seconds: seconds,
                sessions: sessions.count, completion: completion)
        }
        .sorted { $0.seconds > $1.seconds }
    }

    private var selectedAggregate: AttentionMusicAggregate? {
        aggregates.first { $0.id == selectedMusicID } ?? aggregates.first
    }

    var body: some View {
        VStack(spacing: UIScale.pt(16)) {
            musicMetrics
            listeningChart
            if compactLayout {
                ranking
                selectedMusic
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    ranking.frame(maxWidth: .infinity)
                    selectedMusic.frame(width: UIScale.pt(320))
                }
            }
        }
        .onAppear { selectedMusicID = aggregates.first?.id }
    }

    private var musicMetrics: some View {
        let total = store.visibleMedia.reduce(0) { $0 + $1.playedSeconds }
        let foreground = store.visibleMedia.filter(\.foreground).reduce(0) { $0 + $1.playedSeconds }
        let unique = Set(store.visibleMedia.map(\.track)).count
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: UIScale.pt(150)), spacing: UIScale.pt(10))],
            spacing: UIScale.pt(10)
        ) {
            AttentionMetricCard(metric: AttentionMetric(id: "listening", title: "Listening", value: AttentionTime.duration(total, compact: true), detail: "Concurrent with your attention", symbol: "headphones"))
            AttentionMetricCard(metric: AttentionMetric(id: "tracks", title: "Unique tracks", value: "\(unique)", detail: "Ranked by played seconds", symbol: "music.note.list"))
            AttentionMetricCard(metric: AttentionMetric(id: "background", title: "Background", value: total > 0 ? "\(Int((total - foreground) / total * 100))%" : "0%", detail: "Not counted as primary context", symbol: "waveform"))
            AttentionMetricCard(metric: AttentionMetric(id: "completion", title: "Completion", value: "91%", detail: "Average playback completion", symbol: "checkmark.circle"))
        }
    }

    private var listeningChart: some View {
        AttentionPanel(title: "Listening rhythm", subtitle: "Exact played time by day and source") {
            Chart(store.dailySummaries) { summary in
                BarMark(
                    x: .value("Date", summary.date, unit: .day),
                    y: .value("Hours", summary.musicSeconds / 3600))
                    .foregroundStyle(Color.pink.opacity(0.75))
                    .cornerRadius(2)
                LineMark(
                    x: .value("Date", summary.date, unit: .day),
                    y: .value("Focus association", min(4.5, summary.focusSeconds / 7200)))
                    .foregroundStyle(DashSkin.sage)
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: store.selectedRange == .month ? 5 : 1)) {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    AxisGridLine().foregroundStyle(DashSkin.line(dark).opacity(0.4))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(DashSkin.line(dark).opacity(0.5))
                    AxisValueLabel {
                        if let hours = value.as(Double.self) { Text("\(Int(hours))h") }
                    }
                }
            }
            .font(.system(size: UIScale.pt(9)))
            .frame(height: UIScale.pt(200))
        }
    }

    private var ranking: some View {
        AttentionPanel(title: "Top listened", subtitle: "Played seconds, not track starts") {
            VStack(spacing: UIScale.pt(10)) {
                Picker("Group", selection: $store.musicGrouping) {
                    ForEach(["Tracks", "Artists", "Albums", "Services"], id: \.self) { Text($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                ForEach(Array(aggregates.prefix(10).enumerated()), id: \.element.id) { index, item in
                    Button {
                        selectedMusicID = item.id
                    } label: {
                        HStack(spacing: UIScale.pt(10)) {
                            Text("\(index + 1)")
                                .font(DashSkin.mono(9.5, weight: .semibold))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .frame(width: UIScale.pt(18))
                            Image(systemName: store.musicGrouping == "Artists" ? "person.wave.2" : "music.note")
                                .foregroundStyle(Color.pink)
                                .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                                .background(Color.pink.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
                            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                Text(item.title)
                                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                                    .foregroundStyle(DashSkin.ink(dark))
                                Text(item.subtitle)
                                    .font(.system(size: UIScale.pt(8.5)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(AttentionTime.duration(item.seconds, compact: true))
                                .font(DashSkin.mono(9.5, weight: .semibold))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                        .padding(UIScale.pt(7))
                        .background(
                            selectedAggregate?.id == item.id ? Color.pink.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    @ViewBuilder
    private var selectedMusic: some View {
        if let item = selectedAggregate {
            AttentionPanel(title: "Listening detail", subtitle: store.musicGrouping) {
                VStack(alignment: .leading, spacing: UIScale.pt(15)) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: UIScale.pt(48)))
                        .foregroundStyle(Color.pink)
                    Text(item.title)
                        .font(DashSkin.serif(23))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(item.subtitle)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    Divider().overlay(DashSkin.line(dark))
                    detailRow("Played", AttentionTime.duration(item.seconds, compact: true))
                    detailRow("Sessions", "\(item.sessions)")
                    detailRow("Completion", "\(Int(item.completion * 100))%")
                    detailRow("Primary source", "Apple Music")
                    detailRow("Common context", "Xcode")
                    Text("Listening overlapped with 78% of your longest focus blocks. This is an association based on 23 comparable sessions.")
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .padding(UIScale.pt(10))
                        .background(Color.pink.opacity(0.07), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: UIScale.pt(10)))
    }
}
