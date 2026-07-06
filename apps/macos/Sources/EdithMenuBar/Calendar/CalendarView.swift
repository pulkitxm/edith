import EdithKit
import EventKit
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var store: CalendarStore
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"

    private var theme: Color { themeColor(themeName) }

    private var groupedDays: [(day: Date, events: [EKEvent])] {
        CalendarDayEvents.groupedByDay(store.events)
    }

    var body: some View {
        Group {
            if store.authStatus != .fullAccess {
                permissionPrompt
                    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                        store.refreshAuthStatus()
                    }
            } else {
                agenda
            }
        }
        .onAppear { store.refreshAuthStatus() }
    }

    private var agenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if groupedDays.isEmpty {
                    Text("Nothing coming up")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(groupedDays, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            dayHeader(group.day)
                            ForEach(group.events, id: \.eventIdentifier) { row(for: $0) }
                        }
                    }
                }
                Color.clear.frame(height: 1).onAppear { store.loadMore() }
            }
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: scrollHeight)
    }

    private func dayHeader(_ day: Date) -> some View {
        let date = day.formatted(.dateTime.month(.abbreviated).day())
        return Text("\(dayName(day)) · \(date)".uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.tertiary)
    }

    private func row(for event: EKEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeRange(for: event))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let location = event.location, !location.isEmpty,
                    !location.hasPrefix("http")
                {
                    Text(location)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let url = MeetingLink.url(for: event) {
                Button {
                    NSWorkspace.shared.open(url)
                    dismissPanel()
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(providerColor(url))
                }
                .buttonStyle(HoverButtonStyle())
                .help(url.absoluteString)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: event))
    }

    private func dayName(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    private func timeRange(for event: EKEvent) -> String {
        guard !event.isAllDay else { return "All day" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private func providerColor(_ url: URL) -> Color {
        let host = url.host?.lowercased() ?? ""
        if host.contains("zoom.us") { return Color(red: 0.18, green: 0.55, blue: 1.0) }
        if host.contains("meet.google.com") { return Color(red: 0.0, green: 0.67, blue: 0.28) }
        if host.contains("teams.") { return Color(red: 0.38, green: 0.39, blue: 0.65) }
        if host.contains("webex.com") { return Color(red: 0.0, green: 0.74, blue: 0.92) }
        return theme
    }

    private func accessibilityLabel(for event: EKEvent) -> String {
        var parts = [timeRange(for: event), event.title ?? "Untitled"]
        if let location = event.location, !location.isEmpty, !location.hasPrefix("http") {
            parts.append(location)
        }
        if MeetingLink.url(for: event) != nil { parts.append("has meeting link") }
        return parts.joined(separator: ", ")
    }

    private var scrollHeight: CGFloat {
        let groups = groupedDays
        guard !groups.isEmpty else { return 96 }
        var height: CGFloat = 0
        for group in groups {
            height += 26
            height += group.events.reduce(0) { $0 + rowHeight(for: $1) }
        }
        return min(height + 16, 460)
    }

    private func rowHeight(for event: EKEvent) -> CGFloat {
        var height: CGFloat = 20
        if let location = event.location, !location.isEmpty, !location.hasPrefix("http") {
            height += 13
        }
        return height + 8
    }

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            eyebrow("CALENDAR ACCESS")
            Text("Edith needs calendar access to show your schedule.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Calendars")
                    .font(.system(size: 12))
                Spacer()
                Button("Grant…") { store.requestAccess() }
                    .buttonStyle(HoverButtonStyle())
                    .font(.system(size: 11))
                    .foregroundStyle(theme)
                    .help("Opens System Settings on the right pane")
            }
        }
        .card()
    }
}
