import AppKit
import EdithExtensionCore
import SwiftUI

public struct ActivityCalendarGrid<Detail: View>: View {
    let weeks: [ActivityCalendarWeek]
    let dark: Bool
    var cellSize: CGFloat = 14
    var calendar: Calendar = .current
    var showsLegend = true
    var fillsWidth = false
    @ViewBuilder let detail: (ActivityCalendarDay) -> Detail

    public init(
        weeks: [ActivityCalendarWeek], dark: Bool, cellSize: CGFloat = 14,
        calendar: Calendar = .current, showsLegend: Bool = true, fillsWidth: Bool = false,
        @ViewBuilder detail: @escaping (ActivityCalendarDay) -> Detail
    ) {
        self.weeks = weeks; self.dark = dark; self.cellSize = cellSize
        self.calendar = calendar; self.showsLegend = showsLegend; self.fillsWidth = fillsWidth
        self.detail = detail
    }

    @State private var hovered: HoveredCell?
    @State private var availableWidth = 400.0
    @Environment(\.surfacePresentation) private var presentation
    @Environment(\.displayScale) private var displayScale

    private struct HoveredCell: Equatable {
        let week: Int
        let row: Int
        let cell: ActivityCalendarDay
    }

    private var maximumSide: CGFloat { 28 }
    private var weekdayGutter: CGFloat { UIScale.pt(16) }

    private var surfaceCellSize: CGFloat {
        guard presentation != nil, !weeks.isEmpty else { return cellSize }
        return max(
            cellSize,
            min(maximumSide, (availableWidth / UIScale.current - 16) / CGFloat(weeks.count) - 3))
    }

    private var layout: ActivityCalendarLayout {
        let gap = UIScale.pt(3)
        let labelHeight = UIScale.pt(12)
        if fillsWidth, presentation == nil,
            let fitted = ActivityCalendarLayout.filling(
                width: max(0, availableWidth - weekdayGutter), weekCount: weeks.count,
                minimumSide: UIScale.pt(cellSize), maximumSide: UIScale.pt(maximumSide), gap: gap,
                labelHeight: labelHeight, pixelScale: displayScale)
        {
            return fitted
        }
        return ActivityCalendarLayout(
            side: UIScale.pt(surfaceCellSize), gap: gap, labelHeight: labelHeight)
    }

    private var weekdays: [String] {
        (0..<7).map { calendar.veryShortWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    public var body: some View {
        let layout = layout
        VStack(spacing: UIScale.pt(8)) {
            HStack(alignment: .top, spacing: UIScale.pt(4)) {
                VStack(spacing: layout.gap) {
                    Color.clear.frame(height: layout.labelHeight)
                    ForEach(0..<7, id: \.self) { row in
                        Text(row.isMultiple(of: 2) ? weekdays[row] : "")
                            .frame(width: UIScale.pt(12), height: layout.side)
                    }
                }
                .frame(width: UIScale.pt(12))
                .accessibilityHidden(true)
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        cellCanvas(layout)
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                    .defaultScrollAnchor(.trailing)
                }
            }
            .frame(height: layout.height)
            if showsLegend, presentation?.tile.showDetails != false {
                HStack(spacing: UIScale.pt(3)) {
                    Spacer()
                    Text("Less")
                    ForEach(0...ActivityCalendar.levels, id: \.self) { level in
                        RoundedRectangle(cornerRadius: UIScale.pt(2))
                            .fill(ActivityCalendarStyle.color(level, dark: dark))
                            .frame(width: UIScale.pt(10), height: UIScale.pt(10))
                    }
                    Text("More")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Color scale from less to more activity")
            }
        }
        .frame(
            maxWidth: presentation == nil && !fillsWidth
                ? max(weekdayGutter, weekdayGutter + layout.contentWidth(weekCount: weeks.count))
                : .infinity,
            alignment: .leading
        )
        .onGeometryChange(for: Double.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
        .font(.system(size: UIScale.pt(9)))
        .foregroundStyle(DashSkin.inkFaint(dark))
    }

    private func cellCanvas(_ layout: ActivityCalendarLayout) -> some View {
        let contentWidth = layout.contentWidth(weekCount: weeks.count)
        return Canvas { context, _ in
            let radius = UIScale.pt(3)
            let labelColor = DashSkin.inkFaint(dark)
            for (index, week) in weeks.enumerated() {
                let label = monthLabel(at: index)
                if !label.isEmpty {
                    let text = context.resolve(
                        Text(label).font(.system(size: UIScale.pt(9))).foregroundStyle(labelColor))
                    let width = text.measure(in: CGSize(width: 200, height: layout.labelHeight))
                        .width
                    let x = min(layout.origin(week: index, row: 0).x, contentWidth - width)
                    context.draw(
                        text, at: CGPoint(x: max(0, x), y: layout.labelHeight / 2), anchor: .leading
                    )
                }
                for (row, cell) in week.cells.enumerated() where cell.level >= 0 {
                    let point = layout.origin(week: index, row: row)
                    let path = Path(
                        roundedRect: CGRect(
                            x: (point.x * displayScale).rounded() / displayScale, y: point.y,
                            width: layout.cellWidth, height: layout.side),
                        cornerRadius: radius)
                    context.fill(
                        path, with: .color(ActivityCalendarStyle.color(cell.level, dark: dark)))
                }
            }
        }
        .frame(width: contentWidth, height: layout.height, alignment: .leading)
        .accessibilityLabel("Activity calendar")
        .accessibilityChildren {
            HStack(spacing: layout.columnGap) {
                ForEach(weeks) { week in
                    VStack(spacing: layout.gap) {
                        ForEach(week.cells.filter { $0.date != nil }) { cell in
                            Color.clear
                                .frame(width: layout.cellWidth, height: layout.side)
                                .accessibilityLabel("Activity " + cell.id)
                                .accessibilityValue(String(cell.value))
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let hovered {
                let point = layout.origin(week: hovered.week, row: hovered.row)
                RoundedRectangle(cornerRadius: UIScale.pt(3))
                    .strokeBorder(DashSkin.ink(dark).opacity(0.5))
                    .frame(width: layout.cellWidth, height: layout.side)
                    .popover(
                        isPresented: Binding(
                            get: { self.hovered == hovered },
                            set: { if !$0, self.hovered == hovered { self.hovered = nil } }
                        ), arrowEdge: .trailing
                    ) { detail(hovered.cell) }
                    .offset(x: point.x, y: point.y)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let next = cell(at: location, layout: layout)
                if next != hovered { hovered = next }
            case .ended:
                if hovered != nil { hovered = nil }
            }
        }
    }

    private func cell(at location: CGPoint, layout: ActivityCalendarLayout) -> HoveredCell? {
        guard let hit = layout.hit(location, weekCount: weeks.count, rowCount: 7),
            weeks[hit.week].cells.indices.contains(hit.row)
        else { return nil }
        let cell = weeks[hit.week].cells[hit.row]
        return cell.date == nil ? nil : HoveredCell(week: hit.week, row: hit.row, cell: cell)
    }

    private func monthLabel(at index: Int) -> String {
        let following = weeks.dropFirst(index + 1).prefix(2)
        return following.contains { !$0.monthLabel.isEmpty } ? "" : weeks[index].monthLabel
    }
}

public struct ActivityCalendarLayout: Equatable, Sendable {
    public let side: CGFloat
    public let gap: CGFloat
    public let labelHeight: CGFloat
    public let cellWidth: CGFloat
    public let columnGap: CGFloat

    public init(
        side: CGFloat, gap: CGFloat, labelHeight: CGFloat, cellWidth: CGFloat? = nil,
        columnGap: CGFloat? = nil
    ) {
        self.side = side
        self.gap = gap
        self.labelHeight = labelHeight
        self.cellWidth = cellWidth ?? side
        self.columnGap = columnGap ?? gap
    }

    public static func filling(
        width: CGFloat, weekCount: Int, minimumSide: CGFloat, maximumSide: CGFloat, gap: CGFloat,
        labelHeight: CGFloat, pixelScale: CGFloat = 2
    ) -> Self? {
        guard weekCount > 0, width > 0, pixelScale > 0 else { return nil }
        let count = CGFloat(weekCount)
        let fitted = ((width + gap) / count - gap)
        let cellWidth = (fitted * pixelScale).rounded(.down) / pixelScale
        guard cellWidth >= minimumSide else { return nil }
        return Self(
            side: min(cellWidth, maximumSide), gap: gap, labelHeight: labelHeight,
            cellWidth: cellWidth,
            columnGap: weekCount > 1 ? (width - cellWidth * count) / (count - 1) : gap)
    }

    public var height: CGFloat { labelHeight + gap + 7 * side + 6 * gap }

    public func contentWidth(weekCount: Int) -> CGFloat {
        max(0, CGFloat(weekCount) * (cellWidth + columnGap) - columnGap)
    }

    public func origin(week: Int, row: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(week) * (cellWidth + columnGap),
            y: labelHeight + gap + CGFloat(row) * (side + gap))
    }

    public func hit(_ location: CGPoint, weekCount: Int, rowCount: Int) -> (week: Int, row: Int)? {
        let columnPitch = cellWidth + columnGap
        let rowPitch = side + gap
        let top = labelHeight + gap
        guard columnPitch > 0, rowPitch > 0, location.x >= 0, location.y >= top else { return nil }
        let week = Int(location.x / columnPitch)
        let row = Int((location.y - top) / rowPitch)
        guard week < weekCount, row < rowCount else { return nil }
        let corner = origin(week: week, row: row)
        guard location.x <= corner.x + cellWidth, location.y <= corner.y + side else { return nil }
        return (week, row)
    }
}

public enum ActivityCalendarStyle {
    public static func color(_ level: Int, dark: Bool) -> Color {
        switch level {
        case ..<0: .clear
        case 0: DashSkin.grid(dark)
        default:
            {
                let (target, fraction) = (dark ? darkRamp : lightRamp)[
                    min(level, ActivityCalendar.levels) - 1]
                return DashSkin.shifted(DashSkin.accent(dark), toward: target, by: fraction)
            }()
        }
    }

    private static let lightRamp: [(NSColor, CGFloat)] = [
        (.white, 0.7), (.white, 0.5), (.white, 0.3), (.white, 0.1), (.black, 0.15), (.black, 0.35),
    ]
    private static let darkRamp: [(NSColor, CGFloat)] = [
        (.black, 0.5), (.black, 0.3), (.black, 0.1), (.white, 0.1), (.white, 0.3), (.white, 0.5),
    ]
}

public struct ActivityCalendarSkeleton: View {
    var cellSize: CGFloat = 14
    var fillsWidth = false

    public init(cellSize: CGFloat = 14, fillsWidth: Bool = false) {
        self.cellSize = cellSize
        self.fillsWidth = fillsWidth
    }

    public var body: some View {
        SkeletonGroup {
            VStack(alignment: .trailing, spacing: UIScale.pt(8)) {
                HStack(alignment: .top, spacing: UIScale.pt(3)) {
                    ForEach(0..<(fillsWidth ? 52 : 24), id: \.self) { _ in
                        VStack(spacing: UIScale.pt(3)) {
                            SkeletonBlock(width: fillsWidth ? nil : cellSize, height: 12)
                            ForEach(0..<7, id: \.self) { _ in
                                SkeletonBlock(
                                    width: fillsWidth ? nil : cellSize, height: cellSize, corner: 3)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                SkeletonBlock(width: 110, height: 10)
            }
        }
    }
}
