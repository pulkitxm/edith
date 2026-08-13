import AppKit
import EdithKit
import SwiftUI

struct CalendarView: View {
    @Environment(CalendarStore.self) private var store
    private var presenterState = PresenterState.shared
    @AppStorage(AppStorageKeys.Presenter.blurCalendar, store: SharedDefaults.store)
    private var presenterBlurCalendar = true
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    var body: some View {
        Group {
            if store.authStatus != .fullAccess {
                CalendarPermissionPrompt(style: .panel, accentColor: theme)
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
        CalendarAgendaView(
            events: store.events,
            style: .panel,
            accentColor: theme,
            blurEvents: blurCalendar,
            onLoadMore: store.loadMore,
            onOpenMeeting: { url in
                NSWorkspace.shared.open(url)
                dismissPanel()
            }
        )
    }

    private var theme: Color { themeColor(themeName) }

    private var blurCalendar: Bool {
        presenterState.active && presenterBlurCalendar
    }
}
