import AppKit
import EdithKit
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

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            pageHeader
            if store.authStatus != .fullAccess {
                CalendarPermissionPrompt(style: calendarStyle, accentColor: theme)
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
        CalendarAgendaView(
            events: store.events,
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
