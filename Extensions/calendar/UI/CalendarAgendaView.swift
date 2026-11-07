import EdithExtensionUI
import SwiftUI

public struct CalendarAgendaStyle: Equatable {
    public let compact: Bool

    public init(compact: Bool) {
        self.compact = compact
    }

    var daySpacing: CGFloat { UIScale.pt(24) }
    var headerSpacing: CGFloat { UIScale.pt(8) }
    var rowSpacing: CGFloat { UIScale.pt(12) }
    var rowHorizontalPadding: CGFloat { UIScale.pt(16) }
    var rowVerticalPadding: CGFloat { UIScale.pt(12) }
    var barWidth: CGFloat { UIScale.pt(4) }
    var timeWidth: CGFloat { UIScale.pt(compact ? 104 : 128) }
    var detailLeadingPadding: CGFloat {
        rowHorizontalPadding + barWidth + rowSpacing + (compact ? 0 : timeWidth + rowSpacing)
    }

    var contentInsets: EdgeInsets {
        let horizontal = PageMetrics.gutter(compact)
        return EdgeInsets(
            top: UIScale.pt(PageMetrics.pinnedContentTop), leading: horizontal,
            bottom: UIScale.pt(PageMetrics.bottom), trailing: horizontal)
    }
}

public struct CalendarAgendaView: View {
    private let groupedDays: [(day: Date, events: [CalendarEventPayload])]
    private let style: CalendarAgendaStyle
    private let accentColor: Color
    private let blurEvents: Bool
    private let onLoadMore: () -> Void
    private let onOpenMeeting: (CalendarEventPayload) -> Void
    private let onDirections: (CalendarEventPayload) -> Void

    public init(
        days: [(day: Date, events: [CalendarEventPayload])],
        style: CalendarAgendaStyle,
        accentColor: Color,
        blurEvents: Bool,
        onLoadMore: @escaping () -> Void,
        onOpenMeeting: @escaping (CalendarEventPayload) -> Void,
        onDirections: @escaping (CalendarEventPayload) -> Void
    ) {
        groupedDays = days
        self.style = style
        self.accentColor = accentColor
        self.blurEvents = blurEvents
        self.onLoadMore = onLoadMore
        self.onOpenMeeting = onOpenMeeting
        self.onDirections = onDirections
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: style.daySpacing) {
                ForEach(groupedDays, id: \.day) { group in
                    CalendarDaySection(
                        day: group.day,
                        events: group.events,
                        style: style,
                        accentColor: accentColor,
                        blurEvents: blurEvents,
                        onOpenMeeting: onOpenMeeting,
                        onDirections: onDirections
                    )
                }
                Color.clear
                    .frame(height: 1)
                    .onAppear(perform: onLoadMore)
            }
            .padding(style.contentInsets)
        }
        .scrollIndicators(.automatic)
    }
}

private struct CalendarDaySection: View {
    let day: Date
    let events: [CalendarEventPayload]
    let style: CalendarAgendaStyle
    let accentColor: Color
    let blurEvents: Bool
    let onOpenMeeting: (CalendarEventPayload) -> Void
    let onDirections: (CalendarEventPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: style.headerSpacing) {
            CalendarDayHeader(day: day, eventCount: events.count)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                    CalendarEventRow(
                        event: event,
                        style: style,
                        accentColor: accentColor,
                        blurEvents: blurEvents,
                        onOpenMeeting: onOpenMeeting,
                        onDirections: onDirections
                    )
                    if index < events.count - 1 {
                        Divider().padding(.leading, style.rowHorizontalPadding)
                    }
                }
            }
            .edithSurface(cornerRadius: 12)
        }
    }
}

private struct CalendarDayHeader: View {
    let day: Date
    let eventCount: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
            PageCapsLabel(title)
            Text(eventCount == 1 ? "1 event" : "\(eventCount) events")
                .font(.edithText(.caption))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(DashSkin.line(scheme == .dark))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        let date = day.formatted(.dateTime.month(.abbreviated).day())
        return "\(CalendarText.dayName(day)) · \(date)"
    }
}

private struct CalendarEventRow: View {
    @State private var detailsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    let event: CalendarEventPayload
    let style: CalendarAgendaStyle
    let accentColor: Color
    let blurEvents: Bool
    let onOpenMeeting: (CalendarEventPayload) -> Void
    let onDirections: (CalendarEventPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if detailsExpanded {
                Divider()
                    .padding(.leading, style.detailLeadingPadding)
                eventDetails
                    .padding(.leading, style.detailLeadingPadding)
                    .padding(.trailing, style.rowHorizontalPadding)
                    .padding(.vertical, style.rowVerticalPadding)
                    .transition(.opacity)
            }
        }
        .animation(
            Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: detailsExpanded)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: style.rowSpacing) {
            RoundedRectangle(cornerRadius: UIScale.pt(2))
                .fill(CalendarText.calendarColor(for: event, fallback: accentColor))
                .frame(width: style.barWidth)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(CalendarText.startTime(for: event))
                    .font(.edithText(.callout).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                ForEach(timeDetails, id: \.self) { detail in
                    Text(detail)
                        .font(.edithText(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: style.timeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(event.title)
                    .font(.edithText(.body).weight(.medium))
                    .lineLimit(style.compact ? 2 : 1)
                    .presenterCover(blurEvents, dark: scheme == .dark)
                metadata
                if style.compact {
                    actions.padding(.top, UIScale.pt(4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !style.compact {
                actions
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, style.rowHorizontalPadding)
        .padding(.vertical, style.rowVerticalPadding)
    }

    private var timeDetails: [String] {
        guard !event.isAllDay else { return [] }
        guard style.compact else { return CalendarText.timeDetail(for: event).map { [$0] } ?? [] }
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return ["Until \(end)", CalendarText.duration(for: event)]
    }

    private var metadata: some View {
        HStack(spacing: UIScale.pt(12)) { metadataItems }
    }

    @ViewBuilder
    private var metadataItems: some View {
        if let calendar = CalendarText.calendarName(for: event) {
            CalendarMetadataLabel(icon: .calendar, text: calendar)
                .presenterCover(blurEvents, dark: scheme == .dark)
        }
        if let location = CalendarText.visibleLocation(for: event) {
            CalendarMetadataLabel(icon: .location, text: location)
                .presenterCover(blurEvents, dark: scheme == .dark)
        }
        if let attendees = CalendarText.attendeeSummary(for: event) {
            CalendarMetadataLabel(icon: .people, text: attendees)
                .presenterCover(blurEvents, dark: scheme == .dark)
        }
        if event.isRecurring {
            CalendarMetadataLabel(icon: .repeatAll, text: "Recurring")
        }
    }

    private var actions: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            if let url = MeetingLink.url(for: event) {
                PageChip(
                    "Join", icon: .video, active: true,
                    tint: accentColor
                ) {
                    onOpenMeeting(event)
                }
                .help(
                    blurEvents
                        ? "Join meeting" : "Join meeting at \(url.host ?? url.absoluteString)")
            }
            if CalendarEventActions.locationURL(for: event) != nil {
                PageChip("Directions", icon: .map) {
                    onDirections(event)
                }
                .help("Open this location in Maps")
            }
            PageChip("Details", icon: detailsExpanded ? .chevronUp : .chevronDown) {
                detailsExpanded.toggle()
            }
            .help(detailsExpanded ? "Hide event details" : "Show event details")
            .accessibilityValue(detailsExpanded ? "Expanded" : "Collapsed")
        }
    }

    private var eventDetails: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UIScale.pt(16)) { summaryDetails }
                VStack(alignment: .leading, spacing: UIScale.pt(4)) { summaryDetails }
            }
            .presenterCover(blurEvents, dark: scheme == .dark)
            if let attendees = CalendarText.attendeeNames(for: event) {
                CalendarDetailLabel(title: "Attendees", value: attendees, icon: .people)
                    .presenterCover(blurEvents, dark: scheme == .dark)
            }
            if let notes = CalendarText.notes(for: event) {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    PageCapsLabel("Notes")
                    Text(notes)
                        .font(.edithText(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .presenterCover(blurEvents, dark: scheme == .dark)
                }
            }
            if !hasDetails {
                Text("No organizer, attendees or notes for this event.")
                    .font(.edithText(.callout))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasDetails: Bool {
        CalendarText.organizerSummary(for: event) != nil
            || CalendarText.responseSummary(for: event) != nil || event.hasAlarms
            || CalendarText.attendeeNames(for: event) != nil
            || CalendarText.notes(for: event) != nil
    }

    @ViewBuilder
    private var summaryDetails: some View {
        if let organizer = CalendarText.organizerSummary(for: event) {
            CalendarDetailLabel(
                title: "Organizer", value: organizer, icon: .person)
        }
        if let response = CalendarText.responseSummary(for: event) {
            CalendarDetailLabel(
                title: "Responses", value: response, icon: .success)
        }
        if event.hasAlarms {
            CalendarDetailLabel(title: "Reminder", value: "On", icon: .bell)
        }
    }
}

private struct CalendarDetailLabel: View {
    let title: String
    let value: String
    let icon: EdithIcon

    var body: some View {
        HStack(spacing: UIScale.pt(4)) {
            EdithIconView(icon)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.edithText(.callout))
        .lineLimit(1)
    }
}

private struct CalendarMetadataLabel: View {
    let icon: EdithIcon
    let text: String

    var body: some View {
        Label(text, edith: icon)
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
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
        let days = minutes / 1_440
        let hours = minutes % 1_440 / 60
        let remainder = minutes % 60
        if days > 0 {
            let dayText = days == 1 ? "1 day" : "\(days) days"
            return hours == 0 ? dayText : "\(dayText) \(hours) hr"
        }
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

    static func accessibilityLabel(for event: CalendarEventPayload) -> String {
        var parts = [timeRange(for: event), event.title]
        if let location = visibleLocation(for: event) {
            parts.append(location)
        }
        if MeetingLink.url(for: event) != nil { parts.append("has meeting link") }
        return parts.joined(separator: ", ")
    }
}
