import AppKit
import SwiftUI

public struct CalendarAgendaView: View {
    private let events: [CalendarEventPayload]
    private let style: CalendarAgendaStyle
    private let accentColor: Color
    private let blurEvents: Bool
    private let onLoadMore: () -> Void
    private let onOpenMeeting: (URL) -> Void

    private var groupedDays: [(day: Date, events: [CalendarEventPayload])] {
        CalendarDayEvents.groupedByDay(events)
    }

    public init(
        events: [CalendarEventPayload],
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
    private let events: [CalendarEventPayload]
    private let style: CalendarAgendaStyle
    private let accentColor: Color
    private let blurEvents: Bool
    private let onOpenMeeting: (URL) -> Void

    init(
        day: Date,
        events: [CalendarEventPayload],
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
            CalendarDayHeader(day: day, eventCount: events.count, style: style)
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
        ForEach(Array(events.enumerated()), id: \.offset) { index, event in
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
    private let eventCount: Int
    private let style: CalendarAgendaStyle

    init(day: Date, eventCount: Int, style: CalendarAgendaStyle) {
        self.day = day
        self.eventCount = eventCount
        self.style = style
    }

    var body: some View {
        HStack(spacing: style.headerContentSpacing) {
            Text(title)
                .font(.system(size: style.headerSize, weight: .semibold))
                .tracking(style.headerTracking)
                .foregroundStyle(style.headerColor)
            if style.showsEventCount {
                Text(eventCount == 1 ? "1 event" : "\(eventCount) events")
                    .font(.system(size: style.eventCountSize, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.vertical, UIScale.pt(3))
                    .background(.quaternary.opacity(0.45), in: Capsule())
            }
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
    }

    private var title: String {
        let date = day.formatted(.dateTime.month(.abbreviated).day())
        return "\(CalendarText.dayName(day)) · \(date)".uppercased()
    }
}

private struct CalendarEventRow: View {
    @State private var detailsExpanded = false
    private let event: CalendarEventPayload
    private let style: CalendarAgendaStyle
    private let accentColor: Color
    private let blurEvents: Bool
    private let onOpenMeeting: (URL) -> Void

    init(
        event: CalendarEventPayload,
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
        if style.showsRichRows {
            richRow
        } else {
            compactRow
        }
    }

    private var richRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            richSummary
            if detailsExpanded {
                Divider()
                    .padding(.leading, style.richDetailLeadingPadding)
                eventDetails
                    .padding(.leading, style.richDetailLeadingPadding)
                    .padding(.trailing, style.rowHorizontalPadding)
                    .padding(.vertical, UIScale.pt(12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: detailsExpanded)
    }

    private var richSummary: some View {
        HStack(alignment: .top, spacing: style.rowSpacing) {
            RoundedRectangle(cornerRadius: UIScale.pt(2))
                .fill(CalendarText.calendarColor(for: event, fallback: accentColor))
                .frame(width: UIScale.pt(4))
                .frame(minHeight: UIScale.pt(44))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(CalendarText.startTime(for: event))
                    .font(.system(size: style.timeSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let detail = CalendarText.timeDetail(for: event) {
                    Text(detail)
                        .font(.system(size: style.detailSize, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: style.richTimeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text(event.title)
                    .font(.system(size: style.titleSize, weight: .medium))
                    .lineLimit(1)
                    .presenterBlur(blurEvents)
                metadata
            }
            Spacer(minLength: style.trailingSpacerMinLength)
            richActions
        }
        .padding(.horizontal, style.rowHorizontalPadding)
        .padding(.vertical, style.richRowVerticalPadding)
    }

    private var compactRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: style.rowSpacing) {
            Text(CalendarText.timeRange(for: event))
                .font(.system(size: style.timeSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: style.timeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: style.titleLocationSpacing) {
                Text(event.title)
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
            meetingButton
        }
        .padding(.horizontal, style.rowHorizontalPadding)
        .padding(.vertical, style.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CalendarText.accessibilityLabel(for: event))
    }

    @ViewBuilder
    private var metadata: some View {
        HStack(spacing: UIScale.pt(12)) {
            if let calendar = CalendarText.calendarName(for: event) {
                CalendarMetadataLabel(systemImage: "calendar", text: calendar)
            }
            if let location = CalendarText.visibleLocation(for: event) {
                CalendarMetadataLabel(systemImage: "mappin.and.ellipse", text: location)
                    .presenterBlur(blurEvents)
            }
            if let attendees = CalendarText.attendeeSummary(for: event) {
                CalendarMetadataLabel(systemImage: "person.2", text: attendees)
            }
            if event.isRecurring {
                CalendarMetadataLabel(systemImage: "repeat", text: "Recurring")
            }
        }
        .lineLimit(1)
    }

    private var richActions: some View {
        HStack(spacing: UIScale.pt(6)) {
            if let url = MeetingLink.url(for: event) {
                CalendarActionButton(
                    title: "Join",
                    systemImage: "video.fill",
                    color: CalendarText.providerColor(for: url, fallback: accentColor),
                    help: "Join meeting at \(url.host ?? url.absoluteString)"
                ) {
                    onOpenMeeting(url)
                }
            }
            if CalendarEventActions.locationURL(for: event) != nil {
                CalendarActionButton(
                    title: "Directions",
                    systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                    color: .orange,
                    help: "Open this location in Maps"
                ) {
                    CalendarEventActions.openLocation(event)
                }
            }
            CalendarActionButton(
                title: "Details",
                systemImage: detailsExpanded ? "chevron.up" : "chevron.down",
                color: .secondary,
                help: detailsExpanded ? "Hide event details" : "Show event details"
            ) {
                detailsExpanded.toggle()
            }
        }
    }

    private var eventDetails: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(16)) {
                if let organizer = CalendarText.organizerSummary(for: event) {
                    CalendarDetailLabel(
                        title: "Organizer", value: organizer, systemImage: "person.crop.circle")
                }
                if let response = CalendarText.responseSummary(for: event) {
                    CalendarDetailLabel(
                        title: "Responses", value: response, systemImage: "checkmark.circle")
                }
                if event.hasAlarms {
                    CalendarDetailLabel(
                        title: "Reminder", value: "Enabled", systemImage: "bell")
                }
            }
            .presenterBlur(blurEvents)
            if let attendees = CalendarText.attendeeNames(for: event) {
                CalendarDetailLabel(
                    title: "Attendees", value: attendees, systemImage: "person.2"
                )
                .presenterBlur(blurEvents)
            }
            if let notes = CalendarText.notes(for: event) {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Label("Notes", systemImage: "text.alignleft")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(notes)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .presenterBlur(blurEvents)
                }
            }
        }
    }

    @ViewBuilder
    private var meetingButton: some View {
        if let url = MeetingLink.url(for: event) {
            let color = CalendarText.providerColor(for: url, fallback: accentColor)
            Button {
                onOpenMeeting(url)
            } label: {
                if style.showsMeetingLabel {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: style.meetingIconSize, weight: .semibold))
                } else {
                    Image(systemName: "video.fill")
                        .font(.system(size: style.meetingIconSize))
                        .foregroundStyle(color)
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Join meeting at \(url.host ?? url.absoluteString)")
        }
    }
}

private struct CalendarActionButton: View {
    @State private var hovering = false
    let title: String
    let systemImage: String
    let color: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .padding(.horizontal, UIScale.pt(10))
                .padding(.vertical, UIScale.pt(6))
                .foregroundStyle(color)
                .background(color.opacity(hovering ? 0.17 : 0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(hovering ? 0.34 : 0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct CalendarDetailLabel: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: UIScale.pt(5)) {
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: UIScale.pt(10.5), weight: .medium))
        .lineLimit(1)
    }
}

private struct CalendarMetadataLabel: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: UIScale.pt(10.5), weight: .medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
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

enum CalendarText {
    static func dayName(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    static func timeRange(for event: CalendarEventPayload) -> String {
        guard !event.isAllDay else { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    static func startTime(for event: CalendarEventPayload) -> String {
        if event.isAllDay { return "All day" }
        return event.start.formatted(date: .omitted, time: .shortened)
    }

    static func timeDetail(for event: CalendarEventPayload) -> String? {
        guard !event.isAllDay else { return nil }
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "Until \(end) · \(duration(for: event))"
    }

    static func duration(for event: CalendarEventPayload) -> String {
        let minutes = max(0, Int(event.end.timeIntervalSince(event.start) / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        if remainder == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours) hr \(remainder) min"
    }

    static func calendarName(for event: CalendarEventPayload) -> String? {
        let title = event.calendar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty
        else { return nil }
        return title
    }

    static func attendeeSummary(for event: CalendarEventPayload) -> String? {
        let count = event.attendees.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 attendee" : "\(count) attendees"
    }

    static func organizerSummary(for event: CalendarEventPayload) -> String? {
        guard let organizer = event.organizer else { return nil }
        return participantName(organizer)
    }

    static func responseSummary(for event: CalendarEventPayload) -> String? {
        guard !event.attendees.isEmpty else { return nil }
        let order = ["accepted", "tentative", "pending", "declined"]
        let counts = Dictionary(grouping: event.attendees, by: \.status).mapValues(\.count)
        let values = order.compactMap { status -> String? in
            guard let count = counts[status], count > 0 else { return nil }
            return "\(count) \(status)"
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    static func attendeeNames(for event: CalendarEventPayload) -> String? {
        let names = event.attendees.compactMap(participantName)
        guard !names.isEmpty else { return nil }
        let visible = names.prefix(6).joined(separator: ", ")
        let remaining = names.count - min(names.count, 6)
        return remaining > 0 ? "\(visible) +\(remaining) more" : visible
    }

    static func notes(for event: CalendarEventPayload) -> String? {
        guard let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            !notes.isEmpty
        else { return nil }
        return notes
    }

    private static func participantName(_ participant: CalendarParticipantPayload) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        {
            return name
        }
        guard let address = participant.address?.trimmingCharacters(in: .whitespacesAndNewlines),
            !address.isEmpty
        else { return nil }
        return address.replacingOccurrences(of: "mailto:", with: "")
    }

    static func calendarColor(for event: CalendarEventPayload, fallback: Color) -> Color {
        guard let color = event.calendarColor else { return fallback }
        return Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

    static func visibleLocation(for event: CalendarEventPayload) -> String? {
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

    static func accessibilityLabel(for event: CalendarEventPayload) -> String {
        var parts = [timeRange(for: event), event.title]
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

    var headerContentSpacing: CGFloat {
        switch self {
        case .page: return UIScale.pt(10)
        case .panel: return 8
        }
    }

    var showsEventCount: Bool {
        switch self {
        case .page: return true
        case .panel: return false
        }
    }

    var eventCountSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(9.5)
        case .panel: return 9
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

    var showsRichRows: Bool {
        switch self {
        case .page: return true
        case .panel: return false
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

    var richTimeWidth: CGFloat {
        switch self {
        case .page: return UIScale.pt(148)
        case .panel: return 128
        }
    }

    var richDetailLeadingPadding: CGFloat {
        switch self {
        case .page: return UIScale.pt(180)
        case .panel: return 0
        }
    }

    var detailSize: CGFloat {
        switch self {
        case .page: return UIScale.pt(10)
        case .panel: return 10
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

    var showsMeetingLabel: Bool {
        switch self {
        case .page: return true
        case .panel: return false
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

    var richRowVerticalPadding: CGFloat {
        switch self {
        case .page: return UIScale.pt(12)
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

    func fixedHeight(for groups: [(day: Date, events: [CalendarEventPayload])]) -> CGFloat? {
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

    private func panelRowHeight(for event: CalendarEventPayload) -> CGFloat {
        var height: CGFloat = 20
        if CalendarText.visibleLocation(for: event) != nil {
            height += 13
        }
        return height + 8
    }
}
