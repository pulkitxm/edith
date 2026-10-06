import AppKit
import EdithKit
import SwiftUI

struct CalendarPage: View {
    @State private var store = CalendarStore(startImmediately: false)
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

    var body: some View {
        PageWorkspace {
            pageHeader
        } content: {
            if store.authStatus != .fullAccess {
                CalendarPermissionPrompt(style: calendarStyle, accentColor: theme)
                    .frame(maxWidth: UIScale.pt(420))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                agenda
            }
        }
        .navigationTitle("Calendar")
        .pageTask(cancel: store.shutdown) { store.start() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            store.refreshAuthStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) {
            _ in
            store.refreshAuthStatus()
        }
    }

    private var pageHeader: some View {
        PageHeader(
            "Calendar",
            trailing: {
                Button {
                    CalendarEventActions.openCalendar()
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
            onLoadMore: store.loadMore
        )
    }

    private var calendarStyle: CalendarAgendaStyle {
        .page(
            compact: compact,
            rowBackground: DashSkin.paper2(dark),
            strokeColor: DashSkin.line(dark))
    }
}
