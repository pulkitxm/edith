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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }
    private var theme: Color { themeColor(themeName) }
    private var blurCalendar: Bool { store.blurEvents }

    var body: some View {
        PageWorkspace {
            pageHeader
        } content: {
            LoadingContainer(
                state: store.loaded ? .content : store.error == nil ? .loading : .error,
                title: "Calendar unavailable", message: store.error ?? "Reading your schedule.",
                retry: store.refresh
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    if let error = store.error {
                        HStack {
                            Text(error).font(.edithText(.caption)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Retry", action: store.refresh).buttonStyle(.edith(.toolbar))
                        }
                        .padding(.horizontal, UIScale.pt(24))
                    }
                    if !store.authorized {
                        permissionState
                    } else if store.groupedDays.isEmpty {
                        emptyState
                    } else {
                        agenda
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } placeholder: {
                PageSkeleton(layout: .list)
            }
        }
        .navigationTitle("Calendar")
        .pageTask(cancel: store.suspend) { await store.observe() }
    }

    private var permissionState: some View {
        PageEmptyState(
            symbolName: "calendar.badge.exclamationmark",
            title: "Allow Edith to read your calendar",
            message:
                "Edith shows your upcoming meetings here, in the notch and on Home, and can join a call in one click. It only reads events from the macOS Calendar app and never changes them.",
            steps: [
                PageGuideStep(
                    symbolName: "hand.raised", title: "Allow access",
                    detail: "macOS asks once. Choose Allow Full Access."),
                PageGuideStep(
                    symbolName: "calendar", title: "See what is next",
                    detail: "Events from every calendar in the Calendar app appear here."),
                PageGuideStep(
                    symbolName: "video", title: "Join in one click",
                    detail: "Meetings with a call link get a Join button."),
            ],
            primary: PageAction(
                "Allow Calendar Access", symbolName: "calendar.badge.checkmark",
                identifier: "calendar.grant"
            ) { store.perform(.permission) },
            secondary: PageAction(
                "Open System Settings", symbolName: "gearshape", identifier: "calendar.settings"
            ) {
                if let url = CalendarUIEngine.privacySettingsURL { NSWorkspace.shared.open(url) }
            },
            footnote:
                "If you chose Don't Allow before, turn Edith on under Privacy & Security, Calendars.")
    }

    private var emptyState: some View {
        PageEmptyState(
            symbolName: "calendar.badge.checkmark",
            title: "Nothing coming up",
            message:
                "No events were found in your calendars for the next few weeks. Add an event in the Calendar app and it shows up here within seconds.",
            primary: PageAction(
                "Open Calendar", symbolName: "arrow.up.forward.app", identifier: "calendar.open"
            ) { store.perform(.open) },
            footnote: "Edith reads every calendar that is turned on in the Calendar app.")
    }

    private var pageHeader: some View {
        PageHeader(
            "Calendar",
            trailing: {
                Button {
                    store.perform(.open)
                } label: {
                    Label("Open Calendar", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(EdithButtonStyle(.toolbar, tint: theme))
            })
    }

    private var agenda: some View {
        CalendarAgendaView(
            days: store.groupedDays,
            style: calendarStyle,
            accentColor: theme,
            blurEvents: blurCalendar,
            onLoadMore: store.loadMore,
            onOpenMeeting: { store.perform(.join, eventID: $0.id) },
            onDirections: { store.perform(.directions, eventID: $0.id) }
        )
    }

    private var calendarStyle: CalendarAgendaStyle {
        .page(
            compact: compact,
            rowBackground: DashSkin.paper2(dark),
            strokeColor: DashSkin.line(dark))
    }
}
