import EdithKit
import SwiftUI

struct DashboardDateRangePicker: View {
    @Environment(\.colorScheme) private var scheme
    @State private var visibleMonth: Date
    @State private var draftFrom: Date
    @State private var draftTo: Date
    @State private var choosingEnd = false

    let bounds: ClosedRange<Date>
    let onApply: (Date, Date) -> Void
    let onCancel: () -> Void

    private let calendar = Calendar.current

    init(
        from: Date, to: Date, bounds: ClosedRange<Date>,
        onApply: @escaping (Date, Date) -> Void, onCancel: @escaping () -> Void
    ) {
        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: bounds.lowerBound)
        let upper = calendar.startOfDay(for: bounds.upperBound)
        let start = min(max(calendar.startOfDay(for: from), lower), upper)
        let end = min(max(calendar.startOfDay(for: to), lower), upper)
        self.bounds = lower...upper
        self.onApply = onApply
        self.onCancel = onCancel
        _draftFrom = State(initialValue: min(start, end))
        _draftTo = State(initialValue: max(start, end))
        _visibleMonth = State(initialValue: calendar.startOfMonth(containing: max(start, end)))
    }

    private var dark: Bool { scheme == .dark }
    private var accent: Color { DashSkin.accent(dark) }

    var body: some View {
        VStack(spacing: UIScale.pt(14)) {
            rangeHeader
            calendarHeader
            weekdayHeader
            monthGrid
            shortcutRow
            actionRow
        }
        .padding(UIScale.pt(16))
        .frame(width: UIScale.pt(350))
        .background(DashSkin.paper2(dark))
    }

    private var rangeHeader: some View {
        HStack(spacing: UIScale.pt(10)) {
            rangeEndpoint("From", draftFrom, active: choosingEnd)
            Image(systemName: "arrow.right")
                .font(.system(size: UIScale.pt(10), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            rangeEndpoint("To", draftTo, active: !choosingEnd)
        }
    }

    private func rangeEndpoint(_ label: String, _ date: Date, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(label.uppercased())
                .font(DashSkin.mono(8, weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(Self.endpointFormatter.string(from: date))
                .font(DashSkin.mono(11, weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBar(
            cornerRadius: 9,
            fill: active
                ? AnyShapeStyle(accent.opacity(0.12)) : AnyShapeStyle(DashSkin.paper(dark)),
            stroke: active ? accent.opacity(0.5) : DashSkin.line(dark)
        )
    }

    private var calendarHeader: some View {
        HStack {
            calendarNavigation("chevron.left", offset: -1)
            Spacer()
            Text(Self.monthFormatter.string(from: visibleMonth))
                .font(DashSkin.serif(UIScale.pt(15), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            Spacer()
            calendarNavigation("chevron.right", offset: 1)
        }
    }

    private func calendarNavigation(_ icon: String, offset: Int) -> some View {
        let target =
            calendar.date(byAdding: .month, value: offset, to: visibleMonth) ?? visibleMonth
        let disabled =
            offset < 0
            ? target < calendar.startOfMonth(containing: bounds.lowerBound)
            : target > calendar.startOfMonth(containing: bounds.upperBound)
        return Button {
            visibleMonth = target
        } label: {
            Image(systemName: icon)
                .font(.system(size: UIScale.pt(10), weight: .semibold))
                .frame(width: UIScale.pt(28), height: UIScale.pt(24))
                .widgetBar(
                    cornerRadius: 7, fill: DashSkin.paper(dark), stroke: DashSkin.line(dark))
        }
        .buttonStyle(.edith(.borderless))
        .disabled(disabled)
        .opacity(disabled ? 0.32 : 1)
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: dayColumns, spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(DashSkin.mono(8, weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(height: UIScale.pt(18))
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: dayColumns, spacing: UIScale.pt(3)) {
            ForEach(monthDates, id: \.self) { date in
                dayButton(date)
            }
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let available = bounds.contains(date)
        let sameMonth = calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
        let endpoint =
            calendar.isDate(date, inSameDayAs: draftFrom)
            || calendar.isDate(date, inSameDayAs: draftTo)
        let withinRange = date >= draftFrom && date <= draftTo
        return Button {
            select(date)
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(DashSkin.mono(10, weight: endpoint ? .bold : .regular))
                .foregroundStyle(
                    endpoint ? Color.white : DashSkin.ink(dark).opacity(sameMonth ? 1 : 0.38)
                )
                .frame(maxWidth: .infinity)
                .frame(height: UIScale.pt(30))
                .background {
                    if endpoint {
                        Circle().fill(accent).padding(UIScale.pt(1))
                    } else if withinRange {
                        RoundedRectangle(cornerRadius: UIScale.pt(6))
                            .fill(accent.opacity(dark ? 0.2 : 0.13))
                    }
                }
        }
        .buttonStyle(.edith(.borderless))
        .disabled(!available)
        .opacity(available ? 1 : 0.2)
        .accessibilityLabel(Self.accessibilityFormatter.string(from: date))
    }

    private var shortcutRow: some View {
        HStack(spacing: UIScale.pt(6)) {
            shortcut("7 days", days: 7)
            shortcut("30 days", days: 30)
            Button("Month to date") {
                let upper = bounds.upperBound
                draftFrom = max(calendar.startOfMonth(containing: upper), bounds.lowerBound)
                draftTo = upper
                visibleMonth = calendar.startOfMonth(containing: upper)
                choosingEnd = false
            }
            .buttonStyle(.edith(.borderless))
            .font(DashSkin.mono(9))
            .foregroundStyle(DashSkin.inkSoft(dark))
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(5))
            .widgetBar(cornerRadius: 7, fill: DashSkin.paper(dark), stroke: DashSkin.line(dark))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcut(_ title: String, days: Int) -> some View {
        Button(title) {
            let upper = bounds.upperBound
            draftFrom = max(
                calendar.date(byAdding: .day, value: -(days - 1), to: upper) ?? upper,
                bounds.lowerBound)
            draftTo = upper
            visibleMonth = calendar.startOfMonth(containing: upper)
            choosingEnd = false
        }
        .buttonStyle(.edith(.borderless))
        .font(DashSkin.mono(9))
        .foregroundStyle(DashSkin.inkSoft(dark))
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(5))
        .widgetBar(cornerRadius: 7, fill: DashSkin.paper(dark), stroke: DashSkin.line(dark))
    }

    private var actionRow: some View {
        HStack {
            Text(choosingEnd ? "Choose an end date" : "Range ready")
                .font(DashSkin.mono(9))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.edith(.borderless))
                .font(DashSkin.mono(10))
                .foregroundStyle(DashSkin.inkSoft(dark))
            Button("Apply") {
                onApply(min(draftFrom, draftTo), max(draftFrom, draftTo))
            }
            .buttonStyle(.edith(.borderless))
            .font(DashSkin.mono(10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(6))
            .background(accent, in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
        }
        .padding(.top, UIScale.pt(2))
    }

    private var dayColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: UIScale.pt(3)), count: 7)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let split = calendar.firstWeekday - 1
        return Array(symbols[split...]) + Array(symbols[..<split])
    }

    private var monthDates: [Date] {
        let first = calendar.startOfMonth(containing: visibleMonth)
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap {
            calendar.date(byAdding: .day, value: $0 - leading, to: first)
        }
    }

    private func select(_ date: Date) {
        guard bounds.contains(date) else { return }
        if choosingEnd, date >= draftFrom {
            draftTo = date
            choosingEnd = false
        } else {
            draftFrom = date
            draftTo = date
            choosingEnd = true
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static let endpointFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    private static let accessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter
    }()
}

extension Calendar {
    fileprivate func startOfMonth(containing date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}
