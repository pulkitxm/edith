import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct ActivityCalendarGrid<Detail: View>: View {
    let weeks: [ActivityCalendarWeek]
    let dark: Bool
    var cellSize: CGFloat = 14
    var calendar: Calendar = .current
    var showsLegend = true
    @ViewBuilder let detail: (ActivityCalendarDay) -> Detail
    @State private var hovered: HoveredCell?
    @State private var availableWidth = 400.0
    @Environment(\.surfacePresentation) private var presentation
    private var adaptiveCellSize: CGFloat {
        guard presentation != nil, !weeks.isEmpty else { return cellSize }
        return max(
            cellSize, min(28, (availableWidth / UIScale.current - 16) / CGFloat(weeks.count) - 3))
    }

    private var gridHeight: CGFloat { UIScale.pt(12 + 3 + 7 * adaptiveCellSize + 6 * 3) }
    private var gridWidth: CGFloat {
        UIScale.pt(16 + CGFloat(weeks.count) * (adaptiveCellSize + 3) - 3 + 20)
    }
    private var weekdays: [String] {
        (0..<7).map { calendar.veryShortWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        VStack(spacing: UIScale.pt(8)) {
            HStack(alignment: .top, spacing: UIScale.pt(4)) {
                VStack(spacing: UIScale.pt(3)) {
                    Color.clear.frame(height: UIScale.pt(12))
                    ForEach(0..<7, id: \.self) { row in
                        Text(row.isMultiple(of: 2) ? weekdays[row] : "")
                            .frame(width: UIScale.pt(12), height: UIScale.pt(adaptiveCellSize))
                    }
                }
                .frame(width: UIScale.pt(12))
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        cellCanvas
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                    .defaultScrollAnchor(.trailing)
                }
            }
            .frame(height: gridHeight)
            if showsLegend, presentation?.tile.showDetails != false {
                HStack(spacing: UIScale.pt(3)) {
                    Spacer()
                    Text("Less")
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: UIScale.pt(2))
                            .fill(ActivityCalendarStyle.color(level, dark: dark))
                            .frame(width: UIScale.pt(10), height: UIScale.pt(10))
                    }
                    Text("More")
                }
                .padding(.trailing, presentation == nil ? trailingLabelRoom : 0)
            }
        }
        .frame(
            maxWidth: presentation == nil ? max(UIScale.pt(16), gridWidth) : .infinity,
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

    private struct HoveredCell: Equatable {
        let week: Int
        let row: Int
        let cell: ActivityCalendarDay
    }

    private var layout: ActivityCalendarLayout {
        ActivityCalendarLayout(
            side: UIScale.pt(adaptiveCellSize), gap: UIScale.pt(3), labelHeight: UIScale.pt(12))
    }

    private var cellSide: CGFloat { layout.side }
    private var cellGap: CGFloat { layout.gap }
    private var labelHeight: CGFloat { layout.labelHeight }
    private var trailingLabelRoom: CGFloat { UIScale.pt(20) }
    private var canvasWidth: CGFloat {
        max(0, CGFloat(weeks.count) * (cellSide + cellGap) - cellGap)
    }

    private func origin(week: Int, row: Int) -> CGPoint {
        layout.origin(week: week, row: row)
    }

    private var cellCanvas: some View {
        Canvas { context, _ in
            let side = cellSide
            let radius = UIScale.pt(3)
            let labelColor = DashSkin.inkFaint(dark)
            for (index, week) in weeks.enumerated() {
                let label = monthLabel(at: index)
                if !label.isEmpty {
                    let text = Text(label).font(.system(size: UIScale.pt(9))).foregroundStyle(
                        labelColor)
                    context.draw(
                        context.resolve(text),
                        at: CGPoint(x: origin(week: index, row: 0).x, y: labelHeight / 2),
                        anchor: .leading)
                }
                for (row, cell) in week.cells.enumerated() where cell.level >= 0 {
                    let point = origin(week: index, row: row)
                    let path = Path(
                        roundedRect: CGRect(x: point.x, y: point.y, width: side, height: side),
                        cornerRadius: radius)
                    context.fill(
                        path, with: .color(ActivityCalendarStyle.color(cell.level, dark: dark)))
                }
            }
        }
        .frame(width: canvasWidth + trailingLabelRoom, height: gridHeight, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if let hovered {
                let point = origin(week: hovered.week, row: hovered.row)
                RoundedRectangle(cornerRadius: UIScale.pt(3))
                    .strokeBorder(DashSkin.ink(dark).opacity(0.5))
                    .frame(width: cellSide, height: cellSide)
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
                let next = cell(at: location)
                if next != hovered { hovered = next }
            case .ended:
                if hovered != nil { hovered = nil }
            }
        }
    }

    private func cell(at location: CGPoint) -> HoveredCell? {
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

struct ActivityCalendarLayout: Equatable {
    let side: CGFloat
    let gap: CGFloat
    let labelHeight: CGFloat

    func origin(week: Int, row: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(week) * (side + gap),
            y: labelHeight + gap + CGFloat(row) * (side + gap))
    }

    func hit(_ location: CGPoint, weekCount: Int, rowCount: Int) -> (week: Int, row: Int)? {
        let pitch = side + gap
        let top = labelHeight + gap
        guard pitch > 0, location.x >= 0, location.y >= top else { return nil }
        let week = Int(location.x / pitch)
        let row = Int((location.y - top) / pitch)
        guard week < weekCount, row < rowCount else { return nil }
        let corner = origin(week: week, row: row)
        guard location.x <= corner.x + side, location.y <= corner.y + side else { return nil }
        return (week, row)
    }
}

enum ActivityCalendarStyle {
    static func color(_ level: Int, dark: Bool) -> Color {
        switch level {
        case ..<0: .clear
        case 0: DashSkin.grid(dark)
        default: DashSkin.heat(level - 1, dark)
        }
    }
}

struct ActivityCalendarSkeleton: View {
    var cellSize: CGFloat = 14

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .trailing, spacing: UIScale.pt(8)) {
                HStack(alignment: .top, spacing: UIScale.pt(3)) {
                    ForEach(0..<24, id: \.self) { _ in
                        VStack(spacing: UIScale.pt(3)) {
                            SkeletonBlock(width: cellSize, height: 12)
                            ForEach(0..<7, id: \.self) { _ in
                                SkeletonBlock(width: cellSize, height: cellSize, corner: 3)
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
