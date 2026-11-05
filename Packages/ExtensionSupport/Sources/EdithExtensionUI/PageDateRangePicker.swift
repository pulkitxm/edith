import EdithExtensionCore
import SwiftUI

public struct PageDateRangePicker: View {
    @Environment(\.colorScheme) private var scheme
    @State private var draft: DateFilterDraft
    @State private var hovered: DateFilterDay?
    @State private var keyboardActive = false
    @FocusState private var gridFocused: Bool

    private let today: DateFilterDay
    private let calendar: Calendar
    private let onApply: (DateFilterRange) -> Void
    private let onCancel: () -> Void

    public init(
        range: DateFilterRange?, earliest: DateFilterDay? = nil, now: Date = Date(),
        calendar: Calendar = .current, onApply: @escaping (DateFilterRange) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let today = DateFilterDay(date: now, calendar: calendar)
        self.init(
            draft: DateFilterDraft(range: range, earliest: earliest, latest: today), today: today,
            calendar: calendar, onApply: onApply, onCancel: onCancel)
    }

    init(
        draft: DateFilterDraft, today: DateFilterDay, calendar: Calendar,
        onApply: @escaping (DateFilterRange) -> Void, onCancel: @escaping () -> Void
    ) {
        self.today = today
        self.calendar = calendar
        self.onApply = onApply
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
    }

    private var dark: Bool { scheme == .dark }
    private var accent: Color { DashSkin.accent(dark) }
    private var cellHeight: CGFloat { UIScale.pt(30) }
    private var markHeight: CGFloat { UIScale.pt(26) }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            endpoints
            monthHeader
            calendarGrid
            footer
        }
        .padding(UIScale.pt(PageMetrics.cardPadding))
        .frame(minWidth: 0, idealWidth: UIScale.pt(320), maxWidth: UIScale.pt(320))
        .background(DashSkin.paper2(dark))
        .onAppear { gridFocused = true }
    }

    private var endpoints: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            endpoint("Start", day: draft.start, role: .start)
            endpoint("End", day: draft.end, role: .end)
        }
    }

    private func endpoint(
        _ title: String, day: DateFilterDay?, role: DateFilterDraft.Endpoint
    ) -> some View {
        let value = day?.title(calendar: calendar)
        let editing = draft.editing == role
        return Button {
            draft.edit(role)
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                PageCapsLabel(title)
                Text(value ?? "Choose a date")
                    .font(.edithText(.subheadline).weight(.medium).monospacedDigit())
                    .foregroundStyle(value == nil ? DashSkin.inkFaint(dark) : DashSkin.ink(dark))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .edithFieldSurface(focused: editing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel("\(title) date, \(value ?? "not chosen")")
        .accessibilityAddTraits(editing ? .isSelected : [])
    }

    private var monthHeader: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            PageIconChip(icon: .chevronLeft, label: "Previous month") {
                draft.showMonth(offset: -1)
            }
            .disabled(!draft.canShowPreviousMonth)
            Text(draft.visibleMonth.title(calendar: calendar))
                .font(.edithText(.headline))
                .monospacedDigit()
                .foregroundStyle(DashSkin.ink(dark))
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            PageIconChip(icon: .chevronRight, label: "Next month") {
                draft.showMonth(offset: 1)
            }
            .disabled(!draft.canShowNextMonth)
        }
    }

    private var calendarGrid: some View {
        let days = draft.gridDays(firstWeekday: calendar.firstWeekday)
        return VStack(spacing: UIScale.pt(2)) {
            weekdayHeader(days)
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        dayCell(days[row * 7 + column], column: column)
                    }
                }
            }
        }
        .background { keyboardTarget }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar, \(draft.visibleMonth.title(calendar: calendar))")
    }

    private var keyboardTarget: some View {
        Color.clear
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(
                keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .pageUp, .pageDown, .space],
                phases: [.down, .repeat]
            ) { press in
                handle(press.key)
            }
            .accessibilityHidden(true)
    }

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        keyboardActive = true
        switch key {
        case .leftArrow: draft.moveCursor(byDays: -1)
        case .rightArrow: draft.moveCursor(byDays: 1)
        case .upArrow: draft.moveCursor(byDays: -7)
        case .downArrow: draft.moveCursor(byDays: 7)
        case .pageUp: draft.moveCursor(byMonths: -1)
        case .pageDown: draft.moveCursor(byMonths: 1)
        case .space: draft.selectCursor()
        default: return .ignored
        }
        return .handled
    }

    private func weekdayHeader(_ days: [DateFilterDay]) -> some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { column in
                Text(symbols[days[column].weekday - 1])
                    .pageCapsStyle()
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScale.pt(18))
                    .accessibilityHidden(true)
            }
        }
    }

    private func dayCell(_ day: DateFilterDay, column: Int) -> some View {
        let available = draft.allows(day)
        let endpoint = day == draft.start || day == draft.end
        let inRange = draft.range?.contains(day) ?? false
        return Button {
            keyboardActive = false
            draft.select(day)
        } label: {
            Text(String(day.day))
                .font(
                    .edithText(.subheadline)
                        .weight(endpoint || day == today ? .semibold : .regular)
                        .monospacedDigit()
                )
                .foregroundStyle(foreground(day, endpoint: endpoint))
                .frame(maxWidth: .infinity)
                .frame(height: cellHeight)
                .background {
                    rangeBand(day, column: column)
                    mark(day, endpoint: endpoint, available: available)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .focusable(false)
        .disabled(!available)
        .opacity(available ? 1 : 0.28)
        .onHover { hovered = $0 ? day : (hovered == day ? nil : hovered) }
        .accessibilityLabel(day.accessibilityTitle(calendar: calendar))
        .accessibilityValue(accessibilityRole(day))
        .accessibilityAddTraits(inRange || endpoint ? .isSelected : [])
    }

    private func foreground(_ day: DateFilterDay, endpoint: Bool) -> Color {
        if endpoint { return DashSkin.onAccent(dark) }
        let inMonth = DateFilterMonth(containing: day) == draft.visibleMonth
        return (day == today ? accent : DashSkin.ink(dark)).opacity(inMonth ? 1 : 0.38)
    }

    @ViewBuilder
    private func rangeBand(_ day: DateFilterDay, column: Int) -> some View {
        if let range = draft.range, range.days > 1, range.contains(day) {
            let fill = accent.opacity(dark ? 0.24 : 0.14)
            let radius = UIScale.pt(6)
            HStack(spacing: 0) {
                (day == range.first ? Color.clear : fill)
                (day == range.last ? Color.clear : fill)
            }
            .frame(height: markHeight)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: column == 0 ? radius : 0,
                    bottomLeadingRadius: column == 0 ? radius : 0,
                    bottomTrailingRadius: column == 6 ? radius : 0,
                    topTrailingRadius: column == 6 ? radius : 0))
        }
    }

    @ViewBuilder
    private func mark(_ day: DateFilterDay, endpoint: Bool, available: Bool) -> some View {
        ZStack {
            if endpoint {
                Circle().fill(accent)
            } else if available, hovered == day {
                Circle().fill(Color.primary.opacity(0.06))
            }
            if keyboardActive, gridFocused, day == draft.cursor {
                Circle().strokeBorder(
                    endpoint ? DashSkin.onAccent(dark) : accent, lineWidth: UIScale.pt(1.5))
            }
        }
        .frame(maxWidth: markHeight, maxHeight: markHeight)
        .aspectRatio(1, contentMode: .fit)
    }

    private func accessibilityRole(_ day: DateFilterDay) -> String {
        if day == draft.start, day == draft.end { return "Start and end date" }
        if day == draft.start { return "Start date" }
        if day == draft.end { return "End date" }
        return (draft.range?.contains(day) ?? false) ? "In range" : ""
    }

    private var footer: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            Text(status)
                .font(.edithText(.caption))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .buttonStyle(.edith(.secondary))
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            Button("Apply") {
                if let range = draft.range { onApply(range) }
            }
            .buttonStyle(.edith(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canApply)
            .fixedSize()
        }
    }

    private var status: String {
        guard let range = draft.range else {
            return draft.start == nil ? "Choose a start date" : "Choose an end date"
        }
        return range.days == 1 ? "1 day" : "\(range.days) days"
    }
}
