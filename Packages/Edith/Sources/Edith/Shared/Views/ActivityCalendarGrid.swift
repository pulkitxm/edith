import EdithKit
import SwiftUI

struct ActivityCalendarGrid<Detail: View>: View {
    let weeks: [ActivityCalendarWeek]
    let dark: Bool
    var cellSize: CGFloat = 14
    var calendar: Calendar = .current
    var showsLegend = true
    @ViewBuilder let detail: (ActivityCalendarDay) -> Detail
    @State private var hovered: String?

    private var gridHeight: CGFloat { UIScale.pt(12 + 3 + 7 * cellSize + 6 * 3) }
    private var gridWidth: CGFloat {
        UIScale.pt(16 + CGFloat(weeks.count) * (cellSize + 3) - 3)
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
                            .frame(width: UIScale.pt(12), height: UIScale.pt(cellSize))
                    }
                }
                .frame(width: UIScale.pt(12))
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: UIScale.pt(3)) {
                            ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                                VStack(spacing: UIScale.pt(3)) {
                                    Text(monthLabel(at: index))
                                        .fixedSize(horizontal: true, vertical: false)
                                        .frame(
                                            width: UIScale.pt(cellSize), height: UIScale.pt(12),
                                            alignment: .leading)
                                    ForEach(week.cells) { cell in
                                        RoundedRectangle(cornerRadius: UIScale.pt(3))
                                            .fill(
                                                ActivityCalendarStyle.color(cell.level, dark: dark)
                                            )
                                            .frame(
                                                width: UIScale.pt(cellSize),
                                                height: UIScale.pt(cellSize)
                                            )
                                            .overlay {
                                                RoundedRectangle(cornerRadius: UIScale.pt(3))
                                                    .strokeBorder(
                                                        DashSkin.ink(dark).opacity(
                                                            hovered == cell.id ? 0.5 : 0))
                                            }
                                            .onHover { inside in
                                                guard cell.date != nil else { return }
                                                if inside {
                                                    hovered = cell.id
                                                } else if hovered == cell.id {
                                                    hovered = nil
                                                }
                                            }
                                            .popover(
                                                isPresented: Binding(
                                                    get: { hovered == cell.id },
                                                    set: {
                                                        if !$0, hovered == cell.id { hovered = nil }
                                                    }
                                                ), arrowEdge: .trailing
                                            ) { detail(cell) }
                                    }
                                }
                                .frame(width: UIScale.pt(cellSize), alignment: .leading)
                            }
                        }
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                    .defaultScrollAnchor(.trailing)
                }
            }
            .frame(height: gridHeight)
            if showsLegend {
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
            }
        }
        .frame(maxWidth: max(UIScale.pt(16), gridWidth), alignment: .leading)
        .font(.system(size: UIScale.pt(9)))
        .foregroundStyle(DashSkin.inkFaint(dark))
    }

    private func monthLabel(at index: Int) -> String {
        let following = weeks.dropFirst(index + 1).prefix(2)
        return following.contains { !$0.monthLabel.isEmpty } ? "" : weeks[index].monthLabel
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
