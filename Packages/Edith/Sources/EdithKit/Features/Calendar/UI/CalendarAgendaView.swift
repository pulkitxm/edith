import AppKit
import EventKit
import SwiftUI

public struct CalendarAgendaView: View {
    private let events: [EKEvent]
    private let style: CalendarAgendaStyle
    private let accentColor: Color
    private let blurEvents: Bool
    private let onLoadMore: () -> Void
    private let onOpenMeeting: (URL) -> Void

    private var groupedDays: [(day: Date, events: [EKEvent])] {
        CalendarDayEvents.groupedByDay(events)
    }

    public init(
        events: [EKEvent],
        style: CalendarAgendaStyle,
        accentColor: Color,
        blurEvents: Bool,
        onLoadMore: @escaping () -> Void,
        onOpenMeeting: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.events = events
        self.style = style
        self.accentColor = accentColor
        self.blurEvents = blurEvents
        self.onLoadMore = onLoadMore
        self.onOpenMeeting = onOpenMeeting
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: style.daySpacing) {
                if groupedDays.isEmpty {
                    CalendarEmptyState(style: style)
                } else {
                    ForEach(groupedDays, id: \.day) { group in
                        CalendarDaySection(
                            day: group.day,
                            events: group.events,
                            style: style,
                            accentColor: accentColor,
                            blurEvents: blurEvents,
                            onOpenMeeting: onOpenMeeting
                        )
                    }
                }
                Color.clear
                    .frame(height: style.loadMoreSentinelHeight)
                    .onAppear(perform: onLoadMore)
            }
            .padding(style.contentInsets)
        }
        .scrollIndicators(style.showsScrollIndicators ? .automatic : .hidden)
        .frame(height: style.fixedHeight(for: groupedDays))
    }
}

public struct CalendarPermissionPrompt: View {
    private let style: CalendarAgendaStyle
    private let accentColor: Color

    public init(style: CalendarAgendaStyle, accentColor: Color) {
        self.style = style
        self.accentColor = accentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style.permissionSpacing) {
            if style.usesEyebrowFunction {
                eyebrow("CALENDAR ACCESS")
            } else {
                Text("CALENDAR ACCESS")
                    .font(.system(size: style.permissionEyebrowSize, weight: .semibold))
                    .tracking(style.headerTracking)
                    .foregroundStyle(.secondary)
            }
            Text(style.permissionMessage)
                .font(.system(size: style.permissionMessageSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: style.permissionRowSpacing) {
                Image(systemName: style.permissionIcon)
                    .font(.system(size: style.permissionIconSize))
                    .foregroundStyle(.secondary)
                Text("Calendars")
                    .font(.system(size: style.permissionTitleSize))
                Spacer()
                Button("Grant…") { IPC.post(IPC.Name.grantCalendar) }
                    .buttonStyle(HoverButtonStyle())
                    .font(.system(size: style.permissionButtonSize))
                    .foregroundStyle(accentColor)
                    .help("Opens System Settings on the right pane")
            }
        }
        .padding(style.permissionPadding)
        .background(style.permissionBackground)
        .overlay(style.permissionStroke)
    }
}

private struct CalendarDaySection: View {
    private let day: Date
    private let events: [EKEvent]
    private let style: CalendarAgendaStyle
    private let accentColor: Color
    private let blurEvents: Bool
    private let onOpenMeeting: (URL) -> Void

    init(
        day: Date,
        events: [EKEvent],
        style: CalendarAgendaStyle,
        accentColor: Color,
        blurEvents: Bool,
        onOpenMeeting: @escaping (URL) -> Void
    ) {
        self.day = day
        self.events = events
        self.style = style
        self.accentColor = accentColor
        self.blurEvents = blurEvents
        self.onOpenMeeting = onOpenMeeting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.headerToRowsSpacing) {
            CalendarDayHeader(day: day, style: style)
            if style.wrapsRowsInCard {
                VStack(alignment: .leading, spacing: 0) {
                    rows
                }
                .padding(.vertical, style.rowCardVerticalPadding)
                .background(style.rowCardBackground)
                .overlay(style.rowCardStroke)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        ForEach(Array(events.enumerated()), id: \.element.eventIdentifier) { index, event in
            CalendarEventRow(
                event: event,
                style: style,
                accentColor: accentColor,
                blurEvents: blurEvents,
                onOpenMeeting: onOpenMeeting
            )
            if style.wrapsRowsInCard && index < events.count - 1 {
                Divider().opacity(0.5)
            }
        }
    }
}

private struct CalendarDayHeader: View {
    private let day: Date
    private let style: CalendarAgendaStyle

    init(day: Date, style: CalendarAgendaStyle) {
        self.day = day
        self.style = style
    }

    var body: some View {
        Text(title)
            .font(.system(size: style.headerSize, weight: .semibold))
            .tracking(style.headerTracking)
            .foregroundStyle(style.headerColor)
    }

    private var title: String {
        let date = day.formatted(.dateTime.month(.abbreviated).day())
        return "\(CalendarText.dayName(day)) · \(date)".uppercased()
    }
}

private struct CalendarEventRow: View {
    private let event: EKEvent
    private let style: CalendarAgendaStyle
    private let accentColor: Color
    private let blurEvents: Bool
    private let onOpenMeeting: (URL) -> Void

    init(
        event: EKEvent,
        style: CalendarAgendaStyle,
        accentColor: Color,
        blurEvents: Bool,
        onOpenMeeting: @escaping (URL) -> Void
    ) {
        self.event = event
        self.style = style
        self.accentColor = accentColor
        self.blurEvents = blurEvents
        self.onOpenMeeting = onOpenMeeting
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: style.rowSpacing) {
            Text(CalendarText.timeRange(for: event))
                .font(.system(size: style.timeSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: style.timeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: style.titleLocationSpacing) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: style.titleSize))
                    .lineLimit(1)
                    .presenterBlur(blurEvents)
                if let location = CalendarText.visibleLocation(for: event) {
                    Text(location)
                        .font(.system(size: style.locationSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: style.trailingSpacerMinLength)
            if let url = MeetingLink.url(for: event) {
                Button {
                    onOpenMeeting(url)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: style.meetingIconSize))
                        .foregroundStyle(
                            CalendarText.providerColor(for: url, fallback: accentColor))
                }
                .buttonStyle(HoverButtonStyle())
                .help(url.absoluteString)
            }
        }
        .padding(.horizontal, style.rowHorizontalPadding)
        .padding(.vertical, style.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CalendarText.accessibilityLabel(for: event))
    }
}

private struct CalendarEmptyState: View {
    private let style: CalendarAgendaStyle

    init(style: CalendarAgendaStyle) {
        self.style = style
    }

    var body: some View {
        if style.usesEmptyStateText {
            EmptyStateText("Nothing coming up")
        } else {
            Text("Nothing coming up")
                .font(.system(size: style.emptyTextSize))
                .foregroundStyle(.secondary)
                .padding(.vertical, style.emptyVerticalPadding)
                .frame(maxWidth: .infinity)
        }
    }
}

private enum CalendarText {
    static func dayName(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    static func timeRange(for event: EKEvent) -> String {
        guard !event.isAllDay else { return "All day" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    static func visibleLocation(for event: EKEvent) -> String? {
        guard let location = event.location, !location.isEmpty, !location.hasPrefix("http") else {
            return nil
        }
        return location
    }

    static func providerColor(for url: URL, fallback: Color) -> Color {
        let host = url.host?.lowercased() ?? ""
        if host.contains("zoom.us") { return Color(red: 0.18, green: 0.55, blue: 1.0) }
        if host.contains("meet.google.com") { return Color(red: 0.0, green: 0.67, blue: 0.28) }
        if host.contains("teams.") { return Color(red: 0.38, green: 0.39, blue: 0.65) }
        if host.contains("webex.com") { return Color(red: 0.0, green: 0.74, blue: 0.92) }
        return fallback
    }

    static func accessibilityLabel(for event: EKEvent) -> String {
        var parts = [timeRange(for: event), event.title ?? "Untitled"]
        if let location = visibleLocation(for: event) {
            parts.append(location)
        }
        if MeetingLink.url(for: event) != nil { parts.append("has meeting link") }
        return parts.joined(separator: ", ")
    }
}

public enum CalendarAgendaStyle {
    case page(
        compact: Bool,
        rowBackground: Color,
        strokeColor: Color
    )
    case panel

    var daySpacing: CGFloat {
        switch self {
        case .page: return UIScale.pt(20)
        case .panel: return 16
        }
    }

    var headerToRowsSpacing: CGFloat {
        switch self {
        case .page: return UIScale.pt(8)
        case .panel: return 6
        }
    }

    var headerSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(11)
        case .panel: return 10
        }
    }

    var headerTracking: CGFloat {
        switch self {
        case .page: return UIScale.pt(1.2)
        case .panel: return 1.2
        }
    }

    var headerColor: HierarchicalShapeStyle {
        switch self {
        case .page: return .secondary
        case .panel: return .tertiary
        }
    }

    var wrapsRowsInCard: Bool {
        switch self {
        case .page: return true
        case .panel: return false
        }
    }

    var rowCardVerticalPadding: CGFloat {
        switch self {
        case .page: return UIScale.pt(4)
        case .panel: return 0
        }
    }

    var rowCardBackground: some ShapeStyle {
        switch self {
        case let .page(_, rowBackground, _): return rowBackground
        case .panel: return Color.clear
        }
    }

    var rowCardStroke: some View {
        RoundedRectangle(cornerRadius: rowCardRadius)
            .strokeBorder(rowStrokeColor, lineWidth: rowStrokeWidth)
    }

    var rowCardRadius: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 0
        }
    }

    var rowStrokeColor: Color {
        switch self {
        case let .page(_, _, strokeColor): return strokeColor
        case .panel: return .clear
        }
    }

    var rowStrokeWidth: CGFloat {
        switch self {
        case .page: return UIScale.pt(1)
        case .panel: return 0
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 10
        }
    }

    var timeSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 11
        }
    }

    var timeWidth: CGFloat {
        switch self {
        case .page: return UIScale.pt(140)
        case .panel: return 128
        }
    }

    var titleLocationSpacing: CGFloat {
        switch self {
        case .page: return UIScale.pt(2)
        case .panel: return 1
        }
    }

    var titleSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(13.5)
        case .panel: return 13
        }
    }

    var locationSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(11)
        case .panel: return 10
        }
    }

    var trailingSpacerMinLength: CGFloat {
        switch self {
        case .page: return UIScale.pt(8)
        case .panel: return 8
        }
    }

    var meetingIconSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 11
        }
    }

    var rowHorizontalPadding: CGFloat {
        switch self {
        case .page: return UIScale.pt(14)
        case .panel: return 0
        }
    }

    var rowVerticalPadding: CGFloat {
        switch self {
        case .page: return UIScale.pt(8)
        case .panel: return 0
        }
    }

    var contentInsets: EdgeInsets {
        switch self {
        case let .page(compact, _, _):
            let horizontal = UIScale.pt(compact ? 18 : 24)
            return EdgeInsets(
                top: UIScale.pt(10),
                leading: horizontal,
                bottom: 0,
                trailing: horizontal)
        case .panel:
            return EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0)
        }
    }

    var loadMoreSentinelHeight: CGFloat {
        switch self {
        case .page: return UIScale.pt(1)
        case .panel: return 1
        }
    }

    var showsScrollIndicators: Bool {
        switch self {
        case .page: return true
        case .panel: return false
        }
    }

    var usesEmptyStateText: Bool {
        switch self {
        case .page: return false
        case .panel: return true
        }
    }

    var emptyTextSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(13)
        case .panel: return 13
        }
    }

    var emptyVerticalPadding: CGFloat {
        switch self {
        case .page: return UIScale.pt(40)
        case .panel: return 0
        }
    }

    func fixedHeight(for groups: [(day: Date, events: [EKEvent])]) -> CGFloat? {
        switch self {
        case .page:
            return nil
        case .panel:
            guard !groups.isEmpty else { return 96 }
            var height: CGFloat = 0
            for group in groups {
                height += 26
                height += group.events.reduce(0) { $0 + panelRowHeight(for: $1) }
            }
            return min(height + 16, 460)
        }
    }

    var permissionSpacing: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 12
        }
    }

    var permissionEyebrowSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(10)
        case .panel: return 10
        }
    }

    var permissionMessage: String {
        switch self {
        case .page: return "Edith needs calendar access to show your schedule here."
        case .panel: return "Edith needs calendar access to show your schedule."
        }
    }

    var permissionMessageSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 11
        }
    }

    var permissionRowSpacing: CGFloat {
        switch self {
        case .page: return UIScale.pt(8)
        case .panel: return 8
        }
    }

    var permissionIcon: String {
        switch self {
        case .page: return "calendar"
        case .panel: return "circle"
        }
    }

    var permissionIconSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 12
        }
    }

    var permissionTitleSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 12
        }
    }

    var permissionButtonSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(11)
        case .panel: return 11
        }
    }

    var permissionPadding: CGFloat {
        switch self {
        case .page: return UIScale.pt(16)
        case .panel: return 16
        }
    }

    @ViewBuilder
    var permissionBackground: some View {
        switch self {
        case let .page(_, rowBackground, _):
            RoundedRectangle(cornerRadius: UIScale.pt(12)).fill(rowBackground)
        case .panel:
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial)
        }
    }

    var permissionStroke: some View {
        RoundedRectangle(cornerRadius: permissionStrokeRadius)
            .strokeBorder(permissionStrokeColor, lineWidth: permissionStrokeWidth)
    }

    var permissionStrokeRadius: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
        case .panel: return 12
        }
    }

    var permissionStrokeColor: Color {
        switch self {
        case let .page(_, _, strokeColor): return strokeColor
        case .panel: return Color.white.opacity(0.08)
        }
    }

    var permissionStrokeWidth: CGFloat {
        switch self {
        case .page: return UIScale.pt(1)
        case .panel: return 1
        }
    }

    var usesEyebrowFunction: Bool {
        switch self {
        case .page: return false
        case .panel: return true
        }
    }

    private func panelRowHeight(for event: EKEvent) -> CGFloat {
        var height: CGFloat = 20
        if CalendarText.visibleLocation(for: event) != nil {
            height += 13
        }
        return height + 8
    }
}
