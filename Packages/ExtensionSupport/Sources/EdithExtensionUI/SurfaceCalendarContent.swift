import EdithExtensionSupport
import SwiftUI

public struct SurfaceCalendarContent: View {
    let descriptor: SurfaceCalendar
    let tile: SurfaceTile
    let perform: (SurfaceAction) -> Void

    public init(
        calendar: SurfaceCalendar, tile: SurfaceTile, perform: @escaping (SurfaceAction) -> Void
    ) {
        descriptor = calendar; self.tile = tile; self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(descriptor.title).font(.edithText(.caption2)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: UIScale.pt(3)) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: UIScale.pt(3)) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                if let day {
                                    if let action = day.action {
                                        Button {
                                            perform(action)
                                        } label: {
                                            cell(day)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        cell(day)
                                    }
                                } else {
                                    Color.clear.frame(width: cellSize, height: cellSize)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
        }.accessibilityElement(children: .contain).accessibilityLabel(descriptor.title)
    }

    private var cellSize: CGFloat { UIScale.pt(tile.dense ? 8 : 12) }

    private func cell(_ day: SurfaceCalendarDay) -> some View {
        RoundedRectangle(cornerRadius: UIScale.pt(2))
            .fill(tile.highlightColor.opacity(day.level == 0 ? 0.08 : Double(day.level) / 4))
            .frame(width: cellSize, height: cellSize)
            .accessibilityLabel(day.date).accessibilityValue(day.value)
            .help(day.date + (day.value.isEmpty ? "" : ": " + day.value))
    }

    private var weeks: [[SurfaceCalendarDay?]] {
        guard let first = descriptor.days.first?.parsedDate,
            let last = descriptor.days.last?.parsedDate
        else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let offset =
            (calendar.component(.weekday, from: first) - Calendar.current.firstWeekday + 7) % 7
        let values = Dictionary(
            uniqueKeysWithValues: descriptor.days.compactMap { day in
                day.parsedDate.map { ($0, day) }
            })
        let count = min(366, calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        var cells: [SurfaceCalendarDay?] = Array(repeating: nil, count: offset)
        cells += (0..<count).map { index in
            calendar.date(byAdding: .day, value: index, to: first).flatMap { values[$0] }
        }
        while !cells.count.isMultiple(of: 7) { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }
}
