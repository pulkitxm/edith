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
            PageLoading(
                state: store.loaded ? .content : store.error == nil ? .loading : .error,
                title: "Calendar unavailable", message: store.error ?? "Reading your schedule.",
                layout: .list, retry: store.refresh
            ) {
                if !store.authorized {
                    CalendarPermissionPrompt(
                        style: calendarStyle, accentColor: theme,
                        onGrant: { store.perform(.permission) }
                    )
                    .frame(maxWidth: UIScale.pt(420))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    agenda
                }
            }
        }
        .navigationTitle("Calendar")
        .pageTask(cancel: store.suspend) { await store.observe() }
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
