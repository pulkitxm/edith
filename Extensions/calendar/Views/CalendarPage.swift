import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CalendarPage: View {
    private let store: CalendarStore
    private let presentation: CalendarPresentationState

    init(store: CalendarStore, presentation: CalendarPresentationState) {
        self.store = store
        self.presentation = presentation
    }
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }
    private var theme: Color { themeColor(themeName) }
    private var blurCalendar: Bool { presentation.blurEvents }

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
            NotificationCenter.default.publisher(for: CalendarPermission.changed)
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
