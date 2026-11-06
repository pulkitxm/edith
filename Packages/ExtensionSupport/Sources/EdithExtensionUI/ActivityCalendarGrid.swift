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

    private var maximumSide: CGFloat { ActivityCalendarLayout.maximumSide }

    private var short: Bool {
        presentation == nil && !weeks.isEmpty
            && weeks.count <= ActivityCalendarLayout.shortWeeks
    }

    private var labelColumn: CGFloat { UIScale.pt(short ? 20 : 12) }
    private var gutter: CGFloat { labelColumn + UIScale.pt(4) }
    private var columns: Int { short ? 7 : weeks.count }
    private var rows: Int { short ? ActivityCalendarLayout.shortWeeks : 7 }
    private var rowOffset: Int {
        short ? max(0, ActivityCalendarLayout.shortWeeks - weeks.count) : 0
    }

    private var surfaceCellSize: CGFloat {
        guard presentation != nil, !weeks.isEmpty else { return cellSize }
        return max(
            cellSize,
            min(maximumSide, (availableWidth / UIScale.current - 16) / CGFloat(weeks.count) - 3))
    }

    private var layout: ActivityCalendarLayout {
        let gap = UIScale.pt(3)
        let labelHeight = UIScale.pt(12)
        if fillsWidth || short, presentation == nil,
            let fitted = ActivityCalendarLayout.filling(
                width: max(0, availableWidth - gutter), weekCount: columns,
                minimumSide: UIScale.pt(cellSize),
                maximumSide: UIScale.pt(ActivityCalendarLayout.maximumSide), gap: gap,
                labelHeight: labelHeight, pixelScale: displayScale)
        {
            return fitted
        }
        return ActivityCalendarLayout(
            side: UIScale.pt(surfaceCellSize), gap: gap, labelHeight: labelHeight)
    }

    private func gridHeight(_ layout: ActivityCalendarLayout) -> CGFloat {
        layout.labelHeight + layout.gap + CGFloat(rows) * (layout.side + layout.gap) - layout.gap
    }

    private func origin(_ layout: ActivityCalendarLayout, week: Int, row: Int) -> CGPoint {
        short
            ? layout.origin(week: row, row: week + rowOffset)
            : layout.origin(week: week, row: row)
    }

    private var weekdays: [String] {
        (0..<7).map { calendar.veryShortWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    private var sideLabels: [String] {
        guard short else { return (0..<7).map { $0.isMultiple(of: 2) ? weekdays[$0] : "" } }
        let start = weeks.first.flatMap { week in
            week.cells.firstIndex { $0.date != nil }.flatMap { index in
                week.cells[index].date.flatMap {
                    calendar.date(byAdding: .day, value: -index, to: $0)
                }
            }
        }
        return (0..<rows).map { row in
            start.flatMap {
                calendar.date(byAdding: .day, value: 7 * (row - rowOffset), to: $0)
            }.map { String(calendar.component(.day, from: $0)) } ?? ""
        }
    }

    public var body: some View {
        let layout = layout
        let gridWidth = gutter + layout.contentWidth(weekCount: columns)
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(alignment: .top, spacing: UIScale.pt(4)) {
                VStack(alignment: .trailing, spacing: layout.gap) {
                    Color.clear.frame(height: layout.labelHeight)
                    ForEach(Array(sideLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .frame(width: labelColumn, height: layout.side, alignment: .trailing)
                    }
                }
                .frame(width: labelColumn)
                .accessibilityHidden(true)
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        cellCanvas(layout)
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                    .defaultScrollAnchor(.trailing)
                }
            }
            .frame(height: gridHeight(layout))
            .frame(maxWidth: fillsWidth ? gridWidth : nil, alignment: .leading)
            if showsLegend, presentation?.tile.showDetails != false {
                HStack(spacing: UIScale.pt(3)) {
                    Text("Less")
                    ForEach(0...ActivityCalendar.levels, id: \.self) { level in
                        RoundedRectangle(cornerRadius: UIScale.pt(2))
                            .fill(ActivityCalendarStyle.color(level, dark: dark))
                            .frame(width: UIScale.pt(10), height: UIScale.pt(10))
                    }
                    Text("More")
                }
                .fixedSize()
                .frame(minWidth: min(availableWidth, gridWidth), alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Color scale from less to more activity")
            }
        }
        .frame(maxWidth: fillsWidth ? gridWidth : nil, alignment: .leading)
        .frame(
            maxWidth: presentation == nil && !fillsWidth ? max(gutter, gridWidth) : .infinity,
            alignment: fillsWidth && presentation == nil ? .center : .leading
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
        let contentWidth = layout.contentWidth(weekCount: columns)
        return Canvas { context, _ in
            let radius = UIScale.pt(3)
            let labelColor = DashSkin.inkFaint(dark)
            func label(_ string: String, x: CGFloat) {
                let text = context.resolve(
                    Text(string).font(.system(size: UIScale.pt(9))).foregroundStyle(labelColor))
                let width = text.measure(in: CGSize(width: 200, height: layout.labelHeight)).width
                context.draw(
                    text,
                    at: CGPoint(
                        x: max(0, min(x, contentWidth - width)), y: layout.labelHeight / 2),
                    anchor: .leading)
            }
            if short {
                for (column, name) in weekdays.enumerated() {
                    label(name, x: layout.origin(week: column, row: 0).x)
                }
                for row in 0..<rowOffset {
                    for column in 0..<7 {
                        let point = layout.origin(week: column, row: row)
                        context.stroke(
                            Path(
                                roundedRect: CGRect(
                                    x: point.x, y: point.y, width: layout.cellWidth,
                                    height: layout.side), cornerRadius: radius),
                            with: .color(ActivityCalendarStyle.color(0, dark: dark)),
                            lineWidth: 1)
                    }
                }
            }
            for (index, week) in weeks.enumerated() {
                if !short {
                    let month = monthLabel(at: index)
                    if !month.isEmpty { label(month, x: layout.origin(week: index, row: 0).x) }
                }
                for (row, cell) in week.cells.enumerated() {
                    let point = origin(layout, week: index, row: row)
                    let path = Path(
                        roundedRect: CGRect(
                            x: (point.x * displayScale).rounded() / displayScale, y: point.y,
                            width: layout.cellWidth, height: layout.side),
                        cornerRadius: radius)
                    if cell.level >= 0 {
                        context.fill(
                            path, with: .color(ActivityCalendarStyle.color(cell.level, dark: dark)))
                    } else if short {
                        context.stroke(
                            path, with: .color(ActivityCalendarStyle.color(0, dark: dark)),
                            lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: contentWidth, height: gridHeight(layout), alignment: .leading)
        .accessibilityLabel("Activity calendar")
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                    ForEach(Array(week.cells.enumerated()), id: \.element.id) { row, cell in
                        if cell.date != nil {
                            let point = origin(layout, week: index, row: row)
                            Color.clear
                                .frame(width: layout.cellWidth, height: layout.side)
                                .accessibilityLabel("Activity " + cell.id)
                                .accessibilityValue(String(cell.value))
                                .offset(x: point.x, y: point.y)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let hovered {
                let point = origin(layout, week: hovered.week, row: hovered.row)
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
        guard let hit = layout.hit(location, weekCount: columns, rowCount: rows) else {
            return nil
        }
        let (week, row) = short ? (hit.row - rowOffset, hit.week) : (hit.week, hit.row)
        guard weeks.indices.contains(week), weeks[week].cells.indices.contains(row) else {
            return nil
        }
        let cell = weeks[week].cells[row]
        return cell.date == nil ? nil : HoveredCell(week: week, row: row, cell: cell)
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

    public static let shortWeeks = 6
    public static let maximumSide: CGFloat = 28

    public static func fittedWidth(
        available: CGFloat, weekCount: Int, minimumSide: CGFloat = 14, pixelScale: CGFloat = 2
    ) -> CGFloat {
        let short = weekCount <= shortWeeks
        let columns = short ? 7 : max(1, weekCount)
        let gutter = CGFloat(UIScale.pt(short ? 24 : 16))
        let gap = CGFloat(UIScale.pt(3))
        let minimum = CGFloat(UIScale.pt(minimumSide))
        let fitted = filling(
            width: max(0, available - gutter), weekCount: columns, minimumSide: minimum,
            maximumSide: CGFloat(UIScale.pt(maximumSide)), gap: gap, labelHeight: 0,
            pixelScale: pixelScale)
        let side = fitted?.side ?? minimum
        return min(available, gutter + CGFloat(columns) * (side + gap) - gap)
    }

    public static func filling(
        width: CGFloat, weekCount: Int, minimumSide: CGFloat, maximumSide: CGFloat, gap: CGFloat,
        labelHeight: CGFloat, pixelScale: CGFloat = 2
    ) -> Self? {
        guard weekCount > 0, width > 0, pixelScale > 0 else { return nil }
        let count = CGFloat(weekCount)
        let fitted = ((width + gap) / count - gap)
        let side = (min(fitted, maximumSide) * pixelScale + 0.001).rounded(.down) / pixelScale
        guard side >= minimumSide else { return nil }
        let spread = weekCount > 1 ? (width - side * count) / (count - 1) : gap
        return Self(
            side: side, gap: gap, labelHeight: labelHeight, cellWidth: side,
            columnGap: fitted > maximumSide ? gap : max(gap, spread))
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
    @State private var availableWidth: CGFloat = 0

    private static let weeks = 53

    public init(cellSize: CGFloat = 14, fillsWidth: Bool = false) {
        self.cellSize = cellSize
        self.fillsWidth = fillsWidth
    }

    private var side: CGFloat {
        guard fillsWidth,
            let fitted = ActivityCalendarLayout.filling(
                width: max(0, availableWidth / UIScale.current - 16), weekCount: Self.weeks,
                minimumSide: cellSize, maximumSide: ActivityCalendarLayout.maximumSide, gap: 3,
                labelHeight: 12)
        else { return cellSize }
        return fitted.side
    }

    public var body: some View {
        let side = side
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(alignment: .top, spacing: UIScale.pt(3)) {
                    ForEach(0..<(fillsWidth ? Self.weeks : 24), id: \.self) { _ in
                        VStack(spacing: UIScale.pt(3)) {
                            SkeletonBlock(width: side, height: 12)
                            ForEach(0..<7, id: \.self) { _ in
                                SkeletonBlock(width: side, height: side, corner: 3)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                SkeletonBlock(width: 110, height: 10)
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
    }
}
