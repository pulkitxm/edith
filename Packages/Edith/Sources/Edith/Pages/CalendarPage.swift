import AppKit
import EdithKit
import EventKit
import SwiftUI

struct CalendarPage: View {
    @State private var store = CalendarStore()
    private var presenterState = PresenterState.shared
    @AppStorage(AppStorageKeys.Presenter.blurCalendar, store: SharedDefaults.store)
    private var presenterBlurCalendar = true
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }
    private var theme: Color { themeColor(themeName) }
    private var blurCalendar: Bool { presenterState.active && presenterBlurCalendar }

    private var groupedDays: [(day: Date, events: [EKEvent])] {
        CalendarDayEvents.groupedByDay(store.events)
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            pageHeader
            if store.authStatus != .fullAccess {
                permissionPrompt
                    .frame(maxWidth: UIScale.pt(420))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onReceive(
                        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
                    ) { _ in
                        store.refreshAuthStatus()
                    }
            } else {
                agenda
            }
        }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .navigationTitle("Calendar")
        .onAppear { store.refreshAuthStatus() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            store.refreshAuthStatus()
        }
    }

    private var pageHeader: some View {
        PageHeader(
            "Calendar",
            trailing: {
                Button {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                } label: {
                    Label("Open Calendar", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(HoverButtonStyle())
            })
    }

    private var agenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: UIScale.pt(20)) {
                if groupedDays.isEmpty {
                    Text("Nothing coming up")
                        .font(.system(size: UIScale.pt(13)))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, UIScale.pt(40))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(groupedDays, id: \.day) { group in
                        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                            dayHeader(group.day)
                            VStack(alignment: .leading, spacing: UIScale.pt(0)) {
                                ForEach(group.events, id: \.eventIdentifier) { event in
                                    row(for: event)
                                    if event != group.events.last {
                                        Divider().opacity(0.5)
                                    }
                                }
                            }
                            .padding(.vertical, UIScale.pt(4))
                            .background(
                                DashSkin.paper2(dark),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: UIScale.pt(12))
                                    .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
                            )
                        }
                    }
                }
                Color.clear.frame(height: UIScale.pt(1)).onAppear { store.loadMore() }
            }
            .pageContent(compact)
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        let date = day.formatted(.dateTime.month(.abbreviated).day())
        return Text("\(dayName(day)) · \(date)".uppercased())
            .font(.system(size: UIScale.pt(11), weight: .semibold))
            .tracking(UIScale.pt(1.2))
            .foregroundStyle(.secondary)
    }

    private func row(for event: EKEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(12)) {
            Text(timeRange(for: event))
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: UIScale.pt(140), alignment: .leading)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: UIScale.pt(13.5)))
                    .lineLimit(1)
                    .presenterBlur(blurCalendar)
                if let location = event.location, !location.isEmpty,
                    !location.hasPrefix("http")
                {
                    Text(location)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let url = MeetingLink.url(for: event) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(providerColor(url))
                }
                .buttonStyle(HoverButtonStyle())
                .help(url.absoluteString)
            }
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(8))
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

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("CALENDAR ACCESS")
                .font(.system(size: UIScale.pt(10), weight: .semibold))
                .tracking(UIScale.pt(1.2))
                .foregroundStyle(.secondary)
            Text("Edith needs calendar access to show your schedule here.")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: "calendar")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                Text("Calendars")
                    .font(.system(size: UIScale.pt(12)))
                Spacer()
                Button("Grant…") { IPC.post(IPC.Name.grantCalendar) }
                    .buttonStyle(HoverButtonStyle())
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(theme)
                    .help("Opens System Settings on the right pane")
            }
        }
        .padding(UIScale.pt(16))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                DashSkin.line(dark), lineWidth: UIScale.pt(1)))
    }
}
