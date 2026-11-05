import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CalendarPage: View {
    private let store: CalendarUIFacade

    init(store: CalendarUIFacade) {
        self.store = store
    }
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.compactLayout) private var compact

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        PageWorkspace {
            pageHeader
        } content: {
            LoadingContainer(
                state: store.loaded ? .content : store.error == nil ? .loading : .error,
                title: "Calendar unavailable",
                message: store.error ?? "Reading your schedule.",
                retry: store.refresh
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = store.error {
                        PageNotice(
                            "Showing the last schedule Edith read. \(error)",
                            title: "Couldn't refresh your calendar", tone: .warning
                        ) {
                            Button("Retry", action: store.refresh)
                        }
                        .pageGutter(compact)
                        .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                    }
                    if !store.authorized {
                        CalendarCenteredState { permissionState }
                    } else if store.groupedDays.isEmpty {
                        CalendarCenteredState { emptyState }
                    } else {
                        agenda
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } placeholder: {
                PageSkeleton(layout: .list)
                    .pageGutter(compact)
                    .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle("Calendar")
        .pageTask(cancel: store.suspend) { await store.observe() }
    }

    private var permissionState: some View {
        PageEmptyState(
            icon: .calendar,
            title: "Allow Edith to read your calendar",
            message:
                "Edith shows your upcoming meetings here, in the notch and on Home, and can join a call in one click. It only reads events from the macOS Calendar app and never changes them.",
            steps: [
                PageGuideStep(
                    icon: .hand, title: "Allow access",
                    detail: "macOS asks once. Choose Allow Full Access."),
                PageGuideStep(
                    icon: .calendar, title: "See what is next",
                    detail: "Events from every calendar in the Calendar app appear here."),
                PageGuideStep(
                    icon: .video, title: "Join in one click",
                    detail: "Meetings with a call link get a Join button."),
            ],
            primary: PageAction(
                "Allow Calendar Access", icon: .calendar,
                identifier: "calendar.grant"
            ) { store.perform(.permission) },
            secondary: PageAction(
                "Open System Settings", icon: .gear, identifier: "calendar.settings"
            ) {
                if let url = CalendarUIEngine.privacySettingsURL { NSWorkspace.shared.open(url) }
            },
            footnote:
                "If you chose Don't Allow before, turn Edith on under Privacy & Security, Calendars."
        )
    }

    private var emptyState: some View {
        PageEmptyState(
            icon: .calendar,
            title: "Nothing coming up",
            message:
                "No events were found in your calendars for the next \(store.days) days. Add an event in the Calendar app and it shows up here within seconds.",
            primary: PageAction(
                "Open Calendar", icon: .external, identifier: "calendar.open"
            ) { store.perform(.open) },
            footnote: "Edith reads every calendar that is turned on in the Calendar app.")
    }

    private var pageHeader: some View {
        PageHeader(
            "Calendar", subtitle: "Upcoming events from every calendar in the Calendar app.",
            divider: true,
            trailing: {
                if store.authorized {
                    Button {
                        store.perform(.open)
                    } label: {
                        Label("Open Calendar", edith: .external)
                    }
                    .help("Open the macOS Calendar app")
                }
            })
    }

    private var agenda: some View {
        CalendarAgendaView(
            days: store.groupedDays,
            style: CalendarAgendaStyle(compact: compact),
            accentColor: theme,
            blurEvents: store.blurEvents,
            onLoadMore: store.loadMore,
            onOpenMeeting: { store.perform(.join, eventID: $0.id) },
            onDirections: { store.perform(.directions, eventID: $0.id) }
        )
    }
}

private struct CalendarCenteredState<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollIndicators(.automatic)
        }
    }
}
