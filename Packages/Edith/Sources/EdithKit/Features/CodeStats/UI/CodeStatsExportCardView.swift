import AppKit
import SwiftUI

public struct CodeStatsExportDeck: ExportCardDeck {
    public let snapshot: CodeStatsExportSnapshot
    public init(snapshot: CodeStatsExportSnapshot) { self.snapshot = snapshot }
    public var cards: [CodeStatsExportCard] { CodeStatsExportCard.allCases }
    public func title(for card: CodeStatsExportCard) -> String { card.title }
    public func filename(for card: CodeStatsExportCard) -> String { card.filenameStem + ".png" }
    public func content(for card: CodeStatsExportCard) -> some View {
        CodeStatsExportCardView(snapshot: snapshot, card: card)
    }
}

@MainActor
public enum CodeStatsExportRenderer {
    public static let size = ExportCardRenderer.size

    public static func image(
        snapshot: CodeStatsExportSnapshot, card: CodeStatsExportCard, scale: CGFloat = 2
    ) throws -> NSImage {
        try ExportCardRenderer.image(
            CodeStatsExportCardView(snapshot: snapshot, card: card), scale: scale)
    }

    public static func pngData(
        snapshot: CodeStatsExportSnapshot, card: CodeStatsExportCard, scale: CGFloat = 2
    ) throws -> Data {
        try ExportCardRenderer.pngData(
            CodeStatsExportCardView(snapshot: snapshot, card: card), scale: scale)
    }
}

private enum ShareColors {
    static let espresso = Color(red: 0.105, green: 0.082, blue: 0.068)
    static let cocoa = Color(red: 0.19, green: 0.14, blue: 0.115)
    static let rust = Color(red: 0.85, green: 0.36, blue: 0.245)
    static let apricot = Color(red: 0.94, green: 0.56, blue: 0.42)
    static let cream = Color(red: 0.975, green: 0.94, blue: 0.875)
    static let sage = Color(red: 0.49, green: 0.62, blue: 0.53)
    static let sky = Color(red: 0.49, green: 0.65, blue: 0.74)
}

public struct CodeStatsExportCardView: View {
    public let snapshot: CodeStatsExportSnapshot
    public let card: CodeStatsExportCard

    public init(snapshot: CodeStatsExportSnapshot, card: CodeStatsExportCard) {
        self.snapshot = snapshot
        self.card = card
    }

    private var accent: Color {
        switch card {
        case .highlights: ShareColors.rust
        case .languages: ShareColors.sage
        case .rhythm: ShareColors.sky
        }
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [ShareColors.espresso, ShareColors.cocoa],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [accent.opacity(0.22), .clear], center: .topTrailing, startRadius: 0,
                endRadius: 620)
            VStack(alignment: .leading, spacing: 0) {
                header
                Group {
                    switch card {
                    case .highlights: HighlightsContent(snapshot: snapshot, accent: accent)
                    case .languages: LanguagesContent(snapshot: snapshot, accent: accent)
                    case .rhythm: RhythmContent(snapshot: snapshot, accent: accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 52)
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CODE STATS")
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(accent)
            Text(card.title)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(ShareColors.cream)
            Text("\(snapshot.rangeLabel)  ·  \(snapshot.startDay) to \(snapshot.endDay)")
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .foregroundStyle(ShareColors.cream.opacity(0.62))
        }
        .padding(.bottom, 36)
    }

    private var footer: some View {
        HStack {
            Text("Edith")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(ShareColors.cream)
            Spacer()
            Text("your own commits, counted locally")
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .foregroundStyle(ShareColors.cream.opacity(0.5))
        }
    }
}

private struct MetricTile: View {
    let value: String
    let label: String
    let accent: Color
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(ShareColors.cream)
            Text(label.uppercased())
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(accent)
            if let detail {
                Text(detail)
                    .font(.system(size: 22, weight: .regular, design: .rounded))
                    .foregroundStyle(ShareColors.cream.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(ShareColors.cream.opacity(0.06))
        )
    }
}

private struct HighlightsContent: View {
    let snapshot: CodeStatsExportSnapshot
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                MetricTile(
                    value: CodeStatsNumberFormat.grouped(snapshot.commits), label: "Commits",
                    accent: accent, detail: change(snapshot.commitChange))
                MetricTile(
                    value: CodeStatsNumberFormat.compact(snapshot.linesAuthored),
                    label: "Lines authored", accent: accent, detail: change(snapshot.lineChange))
                MetricTile(
                    value: CodeStatsNumberFormat.signed(snapshot.netLines), label: "Net lines",
                    accent: accent,
                    detail:
                        "\(CodeStatsNumberFormat.compact(snapshot.linesDeleted)) deleted")
            }
            HStack(spacing: 20) {
                MetricTile(
                    value: CodeStatsNumberFormat.grouped(snapshot.activeDays),
                    label: "Active days", accent: accent)
                MetricTile(
                    value: CodeStatsNumberFormat.grouped(snapshot.longestStreak),
                    label: "Longest streak", accent: accent,
                    detail: "\(snapshot.currentStreak) current")
                MetricTile(
                    value: CodeStatsNumberFormat.grouped(snapshot.linesPerActiveDay),
                    label: "Lines per active day", accent: accent)
            }
        }
    }

    private func change(_ value: Double?) -> String? {
        value.map { CodeStatsNumberFormat.signedPercent($0) + " vs previous period" }
    }
}

private struct LanguagesContent: View {
    let snapshot: CodeStatsExportSnapshot
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snapshot.languages.isEmpty {
                Text("No languages counted in this range")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .foregroundStyle(ShareColors.cream.opacity(0.6))
            }
            ForEach(Array(snapshot.languages.enumerated()), id: \.offset) { _, language in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(language.name)
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .foregroundStyle(ShareColors.cream)
                        Spacer()
                        Text(CodeStatsNumberFormat.compact(language.lines) + " lines")
                            .font(.system(size: 30, weight: .medium, design: .rounded))
                            .foregroundStyle(ShareColors.cream.opacity(0.7))
                        Text(CodeStatsNumberFormat.percent(language.share * 100))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                            .frame(width: 110, alignment: .trailing)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ShareColors.cream.opacity(0.08))
                            Capsule().fill(accent)
                                .frame(width: max(6, proxy.size.width * min(1, language.share)))
                        }
                    }
                    .frame(height: 6)
                }
            }
            if snapshot.languageCount > snapshot.languages.count {
                Text("and \(snapshot.languageCount - snapshot.languages.count) more")
                    .font(.system(size: 22, weight: .regular, design: .rounded))
                    .foregroundStyle(ShareColors.cream.opacity(0.5))
            }
        }
    }
}

private enum ExportText {
    static func commits(_ count: Int) -> String {
        "\(CodeStatsNumberFormat.grouped(count)) \(count == 1 ? "commit" : "commits")"
    }

    static func day(_ value: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return value }
        parser.dateFormat = "d MMM yyyy"
        return parser.string(from: date)
    }
}

private struct RhythmContent: View {
    let snapshot: CodeStatsExportSnapshot
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                MetricTile(
                    value: snapshot.busiestWeekday ?? "None", label: "Busiest weekday",
                    accent: accent,
                    detail: snapshot.busiestWeekday == nil
                        ? nil : ExportText.commits(snapshot.busiestWeekdayCommits))
                MetricTile(
                    value: snapshot.peakHour.map { String(format: "%02d:00", $0) } ?? "None",
                    label: "Peak hour", accent: accent,
                    detail: snapshot.peakHour == nil
                        ? nil : ExportText.commits(snapshot.peakHourCommits))
            }
            HStack(spacing: 20) {
                MetricTile(
                    value: snapshot.bestDay.map(ExportText.day) ?? "None",
                    label: "Biggest day", accent: accent,
                    detail: snapshot.bestDay == nil
                        ? nil
                        : "\(CodeStatsNumberFormat.compact(snapshot.bestDayLines)) lines, "
                            + ExportText.commits(snapshot.bestDayCommits))
                MetricTile(
                    value: "\(snapshot.longestStreak) days", label: "Longest streak",
                    accent: accent, detail: "\(snapshot.currentStreak) current")
            }
        }
    }
}
