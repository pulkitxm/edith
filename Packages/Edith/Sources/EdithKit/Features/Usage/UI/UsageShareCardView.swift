import AppKit
import SwiftUI

public enum UsageShareRenderingError: LocalizedError {
    case unavailable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "the usage image could not be rendered"
        case .encodingFailed: return "the usage image could not be encoded as PNG"
        }
    }
}

@MainActor
public enum UsageShareRenderer {
    public static let size = CGSize(width: 1_200, height: 800)

    public static func image(
        snapshot: UsageShareSnapshot, card: UsageShareCard, scale: CGFloat = 2
    ) throws -> NSImage {
        let renderer = ImageRenderer(
            content: UsageShareCardView(snapshot: snapshot, card: card)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = scale
        guard let image = renderer.nsImage else { throw UsageShareRenderingError.unavailable }
        return image
    }

    public static func pngData(
        snapshot: UsageShareSnapshot, card: UsageShareCard, scale: CGFloat = 2
    ) throws -> Data {
        let image = try image(snapshot: snapshot, card: card, scale: scale)
        guard let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else { throw UsageShareRenderingError.encodingFailed }
        return data
    }
}

public struct UsageShareCardView: View {
    public let snapshot: UsageShareSnapshot
    public let card: UsageShareCard

    public init(snapshot: UsageShareSnapshot, card: UsageShareCard) {
        self.snapshot = snapshot
        self.card = card
    }

    public var body: some View {
        ZStack {
            EdithShareBackdrop(card: card)
            VStack(alignment: .leading, spacing: 0) {
                ShareCardHeader(card: card)
                Group {
                    switch card {
                    case .highlights:
                        HighlightsShareContent(snapshot: snapshot)
                    case .activity:
                        ActivityShareContent(snapshot: snapshot)
                    case .daily:
                        DailyShareContent(snapshot: snapshot)
                    case .busiest:
                        BusiestShareContent(snapshot: snapshot)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ShareCardFooter()
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 52)
        }
        .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
        .environment(\.colorScheme, .dark)
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
    static let sand = Color(red: 0.76, green: 0.67, blue: 0.53)
}

private struct EdithShareBackdrop: View {
    let card: UsageShareCard

    private var glow: Color {
        switch card {
        case .highlights: return ShareColors.rust
        case .activity: return ShareColors.sage
        case .daily: return ShareColors.sky
        case .busiest: return ShareColors.apricot
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ShareColors.espresso, ShareColors.cocoa],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let spacing: CGFloat = 34
                for x in stride(from: spacing, through: size.width, by: spacing) {
                    for y in stride(from: spacing, through: size.height, by: spacing) {
                        let emphasized = Int(x / spacing + y / spacing) % 5 == 0
                        let dot = CGRect(
                            x: x - (emphasized ? 1.5 : 1), y: y - (emphasized ? 1.5 : 1),
                            width: emphasized ? 3 : 2, height: emphasized ? 3 : 2)
                        context.fill(
                            Path(ellipseIn: dot),
                            with: .color(ShareColors.cream.opacity(emphasized ? 0.09 : 0.035)))
                    }
                }
                let shift = routeShift(for: size)
                let routes = [
                    [
                        CGPoint(x: -20, y: size.height * 0.76),
                        CGPoint(x: size.width * 0.16, y: size.height * 0.76),
                        CGPoint(x: size.width * 0.16, y: size.height * 0.63),
                        CGPoint(x: size.width * 0.31, y: size.height * 0.63),
                    ],
                    [
                        CGPoint(x: size.width * 0.72 + shift, y: -20),
                        CGPoint(x: size.width * 0.72 + shift, y: size.height * 0.17),
                        CGPoint(x: size.width * 0.88, y: size.height * 0.17),
                        CGPoint(x: size.width * 0.88, y: size.height * 0.34),
                        CGPoint(x: size.width + 20, y: size.height * 0.34),
                    ],
                    [
                        CGPoint(x: size.width * 0.49, y: size.height + 20),
                        CGPoint(x: size.width * 0.49, y: size.height * 0.86),
                        CGPoint(x: size.width * 0.62 + shift, y: size.height * 0.86),
                    ],
                ]
                for (index, points) in routes.enumerated() {
                    var route = Path()
                    route.move(to: points[0])
                    for point in points.dropFirst() { route.addLine(to: point) }
                    context.stroke(
                        route,
                        with: .color(glow.opacity(index == 1 ? 0.5 : 0.26)),
                        style: StrokeStyle(
                            lineWidth: index == 1 ? 2.5 : 1.5,
                            lineCap: .round, lineJoin: .round, dash: [8, 10]))
                    for point in points.dropFirst().dropLast() {
                        context.fill(
                            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
                            with: .color(ShareColors.espresso))
                        context.stroke(
                            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
                            with: .color(glow.opacity(0.85)), lineWidth: 2)
                    }
                }
                let locator = CGRect(
                    x: size.width - 138, y: size.height - 154, width: 70, height: 70)
                context.stroke(
                    Path(roundedRect: locator, cornerRadius: 8),
                    with: .color(glow.opacity(0.22)), lineWidth: 1.5)
                context.stroke(
                    Path(roundedRect: locator.insetBy(dx: 12, dy: 12), cornerRadius: 4),
                    with: .color(glow.opacity(0.38)), lineWidth: 1.5)
            }
        }
    }

    private func routeShift(for size: CGSize) -> CGFloat {
        switch card {
        case .highlights: return 0
        case .activity: return -size.width * 0.08
        case .daily: return size.width * 0.06
        case .busiest: return -size.width * 0.14
        }
    }
}

private struct ShareCardHeader: View {
    let card: UsageShareCard

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(card.title)
                .font(.custom("Iowan Old Style", size: 52).weight(.semibold))
                .foregroundStyle(ShareColors.cream)
            Spacer()
            Text("LOCAL USAGE // EDITH")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(ShareColors.cream.opacity(0.62))
        }
        .padding(.bottom, 30)
    }
}

private struct ShareCardFooter: View {
    var body: some View {
        HStack {
            HStack(spacing: 13) {
                Image(nsImage: ShareBrand.icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                Text("edith")
                    .font(.custom("Iowan Old Style", size: 31).weight(.bold))
            }
            Spacer()
            Text("github.com/pulkitxm/edith")
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .tracking(0.3)
        }
        .foregroundStyle(ShareColors.cream)
        .padding(.top, 26)
    }
}

@MainActor
private enum ShareBrand {
    static let icon: NSImage = {
        guard let url = Bundle.module.url(forResource: "appicon", withExtension: "png"),
            let icon = NSImage(contentsOf: url)
        else { preconditionFailure("Edith app icon is missing") }
        return icon
    }()
}

private struct SharePanel: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .background(
                ShareColors.espresso.opacity(0.68),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(accent.opacity(0.3), lineWidth: 1.5)
            }
    }
}

private extension View {
    func sharePanel(accent: Color) -> some View {
        modifier(SharePanel(accent: accent))
    }
}

private struct HighlightsShareContent: View {
    let snapshot: UsageShareSnapshot

    private var metrics: [(String, String, String)] {
        [
            (ShareFormat.tokens(snapshot.totalTokens), "tokens", "put to work"),
            ("\(snapshot.activeDays)", "active days", "in the arena"),
            ("\(snapshot.longestStreak)", "day streak", "longest run"),
            ("\(snapshot.repositoryCount)", "repositories", "moved forward"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("A local record of shipping with agents.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(ShareColors.cream.opacity(0.72))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                    HStack(alignment: .center, spacing: 18) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index == 0 ? ShareColors.rust : ShareColors.sand.opacity(0.65))
                            .frame(width: 6, height: 74)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(metric.0)
                                .font(.custom("Iowan Old Style", size: 38).weight(.bold))
                                .monospacedDigit()
                            Text(metric.1.uppercased())
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                            Text(metric.2)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(ShareColors.cream.opacity(0.5))
                        }
                        Spacer()
                    }
                    .foregroundStyle(ShareColors.cream)
                    .padding(.horizontal, 24)
                    .frame(height: 126)
                    .sharePanel(accent: index == 0 ? ShareColors.rust : ShareColors.sand)
                }
            }
        }
    }
}

private struct ActivityShareContent: View {
    let snapshot: UsageShareSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.activeDays) days of momentum")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Text("\(snapshot.longestStreak) day longest streak")
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(ShareColors.cream.opacity(0.58))
            }
            ActivityHeatGrid(snapshot: snapshot)
        }
        .foregroundStyle(ShareColors.cream)
        .padding(28)
        .sharePanel(accent: ShareColors.sage)
    }
}

private struct ActivityHeatGrid: View {
    let snapshot: UsageShareSnapshot

    private var grid: [UsageShareGridDay] { UsageShareGrid.make(snapshot: snapshot) }
    private var weeks: [[UsageShareGridDay]] {
        stride(from: 0, to: grid.count, by: 7).map {
            Array(grid[$0..<min($0 + 7, grid.count)])
        }
    }
    private var maximum: Double { max(1, snapshot.days.map(\.tokens).max() ?? 0) }

    var body: some View {
        let renderedWeeks = weeks
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                ForEach(
                    Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()),
                    id: \.offset
                ) { _, label in
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ShareColors.cream.opacity(0.45))
                        .frame(width: 18, height: 22)
                }
            }
            .padding(.top, 24)
            HStack(alignment: .top, spacing: 7) {
                ForEach(Array(renderedWeeks.enumerated()), id: \.offset) { index, week in
                    VStack(spacing: 6) {
                        Color.clear
                            .frame(width: 22, height: 18)
                            .overlay(alignment: .leading) {
                                Text(monthLabel(at: index, in: renderedWeeks))
                                    .font(
                                        .system(size: 10, weight: .semibold, design: .monospaced)
                                    )
                                    .foregroundStyle(ShareColors.cream.opacity(0.48))
                                    .fixedSize()
                            }
                        ForEach(week) { day in
                            RoundedRectangle(cornerRadius: 5)
                                .fill(color(for: day.tokens))
                                .frame(width: 22, height: 22)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func monthLabel(at index: Int, in weeks: [[UsageShareGridDay]]) -> String {
        guard let period = weeks[index].first?.id,
            let date = UsageShareSnapshot.date(from: period)
        else { return "" }
        if index == 0, weeks.count > 1, let nextPeriod = weeks[1].first?.id,
            let next = UsageShareSnapshot.date(from: nextPeriod),
            Calendar(identifier: .gregorian).component(.month, from: next)
                != Calendar(identifier: .gregorian).component(.month, from: date)
        {
            return ""
        }
        if index > 0, let previousPeriod = weeks[index - 1].first?.id,
            let previous = UsageShareSnapshot.date(from: previousPeriod),
            Calendar(identifier: .gregorian).component(.month, from: previous)
                == Calendar(identifier: .gregorian).component(.month, from: date)
        {
            return ""
        }
        return date.formatted(.dateTime.month(.abbreviated))
    }

    private func color(for tokens: Double) -> Color {
        guard tokens > 0 else { return ShareColors.cream.opacity(0.08) }
        let intensity = log10(tokens + 1) / log10(maximum + 1)
        if intensity < 0.35 { return ShareColors.sage.opacity(0.42) }
        if intensity < 0.58 { return ShareColors.sage.opacity(0.66) }
        if intensity < 0.8 { return ShareColors.sage.opacity(0.84) }
        return ShareColors.cream.opacity(0.92)
    }
}

private struct DailyShareContent: View {
    let snapshot: UsageShareSnapshot

    private var days: [UsageShareDay] { Array(snapshot.days.suffix(30)) }
    private var maximum: Double { max(1, days.map(\.tokens).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(ShareFormat.tokens(snapshot.totalTokens))
                        .font(.custom("Iowan Old Style", size: 50).weight(.bold))
                    Text("TOTAL TOKENS")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(ShareColors.cream.opacity(0.54))
                }
                Spacer()
                Text("last \(days.count) days")
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(ShareColors.cream.opacity(0.58))
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days, id: \.period) { day in
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [ShareColors.sky, ShareColors.rust],
                                    startPoint: .bottom, endPoint: .top)
                            )
                            .frame(height: max(5, 200 * day.tokens / maximum))
                        if labelShown(day) {
                            Text(ShareFormat.day(day.period))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ShareColors.cream.opacity(0.48))
                        } else {
                            Color.clear.frame(height: 13)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 228, alignment: .bottom)
        }
        .foregroundStyle(ShareColors.cream)
        .padding(28)
        .sharePanel(accent: ShareColors.sky)
    }

    private func labelShown(_ day: UsageShareDay) -> Bool {
        guard let index = days.firstIndex(where: { $0.period == day.period }) else { return false }
        return index == 0 || index == days.count - 1 || index % 7 == 0
    }
}

private struct BusiestShareContent: View {
    let snapshot: UsageShareSnapshot

    private var busiest: UsageShareDay {
        snapshot.busiestDay ?? UsageShareDay(period: "", tokens: 0, cost: 0)
    }
    private var multiplier: Double {
        guard snapshot.averageTokensPerActiveDay > 0 else { return 0 }
        return busiest.tokens / snapshot.averageTokensPerActiveDay
    }

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text(ShareFormat.longDate(busiest.period))
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ShareColors.cream.opacity(0.58))
                Text(ShareFormat.tokens(busiest.tokens))
                    .font(.custom("Iowan Old Style", size: 80).weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text("tokens in one day")
                    .font(.system(size: 24, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 18) {
                BusiestStat(
                    value: String(format: "%.1fx", multiplier), label: "your daily average")
                BusiestStat(value: "\(snapshot.agentCount)", label: "agents in your story")
            }
            .frame(width: 310)
        }
        .foregroundStyle(ShareColors.cream)
        .padding(38)
        .sharePanel(accent: ShareColors.apricot)
    }
}

private struct BusiestStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.custom("Iowan Old Style", size: 36).weight(.bold))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(ShareColors.cream.opacity(0.52))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            ShareColors.cream.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct UsageShareGridDay: Identifiable {
    let id: String
    let tokens: Double
}

private enum UsageShareGrid {
    static func make(snapshot: UsageShareSnapshot) -> [UsageShareGridDay] {
        let calendar = Calendar(identifier: .gregorian)
        let values = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.period, $0.tokens) })
        let endValue = snapshot.days.last.flatMap { UsageShareSnapshot.date(from: $0.period) } ?? Date()
        let end = calendar.startOfDay(for: endValue)
        let windowStart = calendar.date(byAdding: .day, value: -181, to: end) ?? end
        let first = windowStart
        let startOffset = calendar.component(.weekday, from: first) - 1
        let start = calendar.date(byAdding: .day, value: -startOffset, to: first) ?? first
        let endOffset = 7 - calendar.component(.weekday, from: end)
        let finish = calendar.date(byAdding: .day, value: endOffset, to: end) ?? end
        let count = (calendar.dateComponents([.day], from: start, to: finish).day ?? 0) + 1
        return (0..<max(7, count)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            let period = ShareFormat.period(date)
            return UsageShareGridDay(id: period, tokens: values[period] ?? 0)
        }
    }
}

private enum ShareFormat {
    static func tokens(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(Int(value.rounded()))
    }

    static func day(_ period: String) -> String {
        guard let date = UsageShareSnapshot.date(from: period) else { return "" }
        return date.formatted(.dateTime.day())
    }

    static func longDate(_ period: String) -> String {
        guard let date = UsageShareSnapshot.date(from: period) else { return "NO DATA YET" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()).uppercased()
    }

    static func period(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
