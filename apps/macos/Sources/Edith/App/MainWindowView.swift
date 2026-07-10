import AppKit
import EdithKit
import SwiftUI

enum MainDestination: String, CaseIterable, Identifiable {
    case home, dashboard, music, calendar, system
    case extensions, shortcuts, settings, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .dashboard: return "Agent Usage"
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .system: return "System"
        case .extensions: return "Extensions"
        case .shortcuts: return "Shortcuts"
        case .settings: return "Settings"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .dashboard: return "chart.bar.fill"
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .system: return "cpu"
        case .extensions: return "puzzlepiece.extension"
        case .shortcuts: return "command"
        case .settings: return "gearshape"
        case .permissions: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }

    static let homeItems: [MainDestination] = [.home, .dashboard, .music, .calendar, .system]
    static let appItems: [MainDestination] = [
        .settings, .extensions, .permissions, .shortcuts, .about,
    ]

    static func visibleHomeItems(
        usage: Bool, music: Bool, calendar: Bool, system: Bool
    ) -> [MainDestination] {
        homeItems.filter { item in
            switch item {
            case .dashboard: return usage
            case .music: return music
            case .calendar: return calendar
            case .system: return system
            default: return true
            }
        }
    }

    static func resolve(_ raw: String, visibleHome: [MainDestination]) -> MainDestination {
        let destination = MainDestination(rawValue: raw) ?? .home
        return visibleHome.contains(destination) || appItems.contains(destination)
            ? destination : .home
    }

    var usesPaperBackground: Bool { Self.homeItems.contains(self) }
}

enum Brand {
    static let icon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        let devBundle = Bundle.main.bundleURL.appendingPathComponent("Edith_Edith.bundle")
        if let bundle = Bundle(url: devBundle),
            let url = bundle.url(forResource: "appicon", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return nil
    }()
}

struct TitlebarChrome: View {
    let height: CGFloat
    let width: CGFloat
    @AppStorage("mainSidebarOpen", store: SharedDefaults.store) private var sidebarOpen = true

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                sidebarOpen.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Toggle sidebar (⌘B)")
            .keyboardShortcut("b", modifiers: .command)

            if sidebarOpen, width >= 130 {
                HStack(alignment: .center, spacing: 7) {
                    if let icon = Brand.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 19, height: 19)
                    }
                    Text("Edith")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }
}

private struct SidebarNavRow: View {
    let item: MainDestination
    let selected: Bool
    let theme: Color
    let action: () -> Void
    @State private var hovering = false

    private var rowBackground: AnyShapeStyle {
        if selected { return AnyShapeStyle(.primary.opacity(0.09)) }
        if hovering { return AnyShapeStyle(.primary.opacity(0.05)) }
        return AnyShapeStyle(.clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(theme) : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                Text(item.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

private struct NavStack {
    private(set) var entries: [String] = []
    private(set) var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    mutating func record(_ location: String) {
        if index >= 0, entries[index] == location { return }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(location)
        index = entries.count - 1
    }

    mutating func goBack() -> String? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func goForward() -> String? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}

struct MainWindowView: View {
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage("settingsTab", store: SharedDefaults.store) private var settingsTab = "general"
    @AppStorage("mainSidebarOpen", store: SharedDefaults.store) private var sidebarOpen = true
    @AppStorage("mainSidebarWidth", store: SharedDefaults.store) private var sidebarWidth = 230.0
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = true
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = true
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        true
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenterMode = false
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("creditHidden", store: SharedDefaults.store) private var creditHidden = false
    @State private var dragBaseWidth: Double?
    @State private var musicKeyMonitor: Any?
    @State private var nav = NavStack()
    @State private var restoringHistory = false
    @State private var permissionsNeedAttention = PermissionsStatus.current
    @Environment(\.colorScheme) private var scheme

    private var theme: Color { themeColor(themeName) }

    private static let minSidebarWidth = 180.0
    private static let maxSidebarWidth = 320.0

    private var clampedSidebarWidth: Double {
        min(Self.maxSidebarWidth, max(Self.minSidebarWidth, sidebarWidth))
    }

    private var destination: MainDestination {
        MainDestination.resolve(mainWindowSection, visibleHome: visibleHomeItems)
    }

    private var visibleHomeItems: [MainDestination] {
        MainDestination.visibleHomeItems(
            usage: usageEnabled, music: musicEnabled, calendar: calendarEnabled,
            system: systemEnabled)
    }

    private var currentLocation: String {
        destination == .settings ? "settings/\(settingsTab)" : mainWindowSection
    }

    private func navigate(to location: String) {
        restoringHistory = true
        if location.hasPrefix("settings/") {
            settingsTab = String(location.dropFirst("settings/".count))
            mainWindowSection = MainDestination.settings.rawValue
        } else {
            mainWindowSection = location
        }
    }

    private func goBack() {
        if let location = nav.goBack() { navigate(to: location) }
    }

    private func goForward() {
        if let location = nav.goForward() { navigate(to: location) }
    }

    var body: some View {
        GeometryReader { geo in
            let bandHeight = max(geo.safeAreaInsets.top, 28)
            VStack(spacing: 0) {
                mainArea(bandHeight)
                if musicFooterVisible {
                    MusicFooter()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) { chromeOverlay(bandHeight) }
            .animation(
                .spring(response: 0.32, dampingFraction: 0.86),
                value: musicFooterVisible)
        }
        .background(historyShortcuts)
        .onChange(of: currentLocation) { _, location in
            if restoringHistory {
                restoringHistory = false
            } else {
                nav.record(location)
            }
        }
        .onAppear {
            MusicRemote.shared.start()
            refreshPermissionsPill()
            installMusicKeys()
            if nav.entries.isEmpty { nav.record(currentLocation) }
        }
        .onDisappear { removeMusicKeys() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshPermissionsPill()
        }
    }

    private var historyShortcuts: some View {
        ZStack {
            Button("", action: goBack)
                .keyboardShortcut("[", modifiers: .command)
            Button("", action: goForward)
                .keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func installMusicKeys() {
        guard musicKeyMonitor == nil else { return }
        musicKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            let mods = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                let remote = MusicRemote.shared
                return MusicKeyCommand.handle(
                    keyCode: code, modifiers: mods, active: remote.current != nil,
                    .init(
                        playPause: { remote.playPause() },
                        seekBy: { remote.nudgeSeek($0) },
                        volumeBy: { remote.nudgeVolume($0) }))
            }
            return handled ? nil : event
        }
    }

    private func removeMusicKeys() {
        if let monitor = musicKeyMonitor {
            NSEvent.removeMonitor(monitor)
            musicKeyMonitor = nil
        }
    }

    private var musicFooterVisible: Bool {
        musicEnabled
    }

    private var detailShadow: Color {
        scheme == .dark ? .black.opacity(0.55) : .black.opacity(0.16)
    }

    private var detailCorner: CGFloat { sidebarOpen ? 12 : 0 }

    private func mainArea(_ bandHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            sidebar(bandHeight)
                .frame(width: clampedSidebarWidth, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            detailColumn(bandHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: detailCorner, bottomLeadingRadius: detailCorner,
                        style: .continuous)
                )
                .padding(.leading, sidebarOpen ? clampedSidebarWidth : 0)
                .shadow(color: detailShadow, radius: 18, x: -6, y: 0)

            sidebarEdge
                .frame(maxHeight: .infinity)
                .offset(x: sidebarOpen ? clampedSidebarWidth : 0)
                .opacity(sidebarOpen ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: sidebarOpen)
    }

    private func refreshPermissionsPill() {
        IPC.post(IPC.Name.requestPermissionsRefresh)
        permissionsNeedAttention = PermissionsStatus.current
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            permissionsNeedAttention = PermissionsStatus.current
        }
    }

    private func chromeOverlay(_ bandHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            TitlebarChrome(
                height: min(bandHeight, 52),
                width: sidebarOpen ? max(clampedSidebarWidth - 94, 60) : 200)
            Spacer(minLength: 0)
        }
        .padding(.leading, 94)
        .ignoresSafeArea(edges: .top)
    }

    private func band(_ color: Color, height: CGFloat) -> some View {
        color
            .frame(height: height)
            .allowsHitTesting(false)
    }

    private func detailColumn(_ bandHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            band(
                destination.usesPaperBackground
                    ? DashSkin.paper(scheme == .dark) : Color(nsColor: .windowBackgroundColor),
                height: bandHeight)
            detail
                .tint(theme)
        }
    }

    private var footerVisible: Bool {
        systemEnabled || permissionsNeedAttention
    }

    private func sidebar(_ bandHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            band(Color(nsColor: .windowBackgroundColor), height: bandHeight)
            VStack(spacing: 0) {
                sidebarList
                if footerVisible {
                    Divider()
                    sidebarFooter
                }
                credit
                    .padding(.vertical, 8)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var sidebarList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleHomeItems) { item in
                    SidebarNavRow(
                        item: item, selected: destination == item, theme: theme
                    ) {
                        mainWindowSection = item.rawValue
                    }
                }
                Text("App")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                ForEach(MainDestination.appItems) { item in
                    SidebarNavRow(
                        item: item, selected: destination == item, theme: theme
                    ) {
                        mainWindowSection = item.rawValue
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            if systemEnabled {
                quickActions
            }
            if permissionsNeedAttention {
                permissionsPill
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var quickActions: some View {
        let tiles = [
            quickActionTile(
                icon: "keyboard", title: "Clean keys", active: false,
                help: "Lock the keyboard so you can wipe it"
            ) {
                IPC.post(IPC.Name.requestKeyboardClean)
            },
            quickActionTile(
                icon: preventSleep ? "moon.zzz.fill" : "moon.zzz", title: "Keep awake",
                active: preventSleep,
                help: "Keep this Mac from sleeping until turned off"
            ) {
                preventSleep.toggle()
            },
        ]
        let presenterTile = quickActionTile(
            icon: "theatermasks.fill", title: "Presenter mode", active: presenterMode,
            help: "Blur sensitive numbers and track names everywhere in Edith"
        ) {
            presenterMode.toggle()
        }
        VStack(spacing: 8) {
            if clampedSidebarWidth < 220 {
                tiles[0]; tiles[1]
            } else {
                HStack(spacing: 8) {
                    tiles[0]; tiles[1]
                }
            }
            presenterTile
        }
    }

    private func quickActionTile(
        icon: String, title: String, active: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(
                active ? AnyShapeStyle(theme) : AnyShapeStyle(.primary.opacity(0.05)),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    private var sidebarEdge: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragBaseWidth ?? clampedSidebarWidth
                                dragBaseWidth = base
                                sidebarWidth = min(
                                    Self.maxSidebarWidth,
                                    max(Self.minSidebarWidth, base + value.translation.width))
                            }
                            .onEnded { _ in dragBaseWidth = nil }
                    )
            }
    }

    @ViewBuilder
    private var credit: some View {
        if !creditHidden {
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                Text("Made with ♥ by")
                    .foregroundStyle(.tertiary)
                Button("Pulkit") {
                    NSWorkspace.shared.open(URL(string: "https://pulkit.page")!)
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(theme)
                .pointerCursor()
                .help("pulkit.page")
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { creditHidden = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Hide this")
            }
            .font(.system(size: 10))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private var permissionsPill: some View {
        Button {
            mainWindowSection = MainDestination.permissions.rawValue
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Permissions need attention")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .home: HomePage()
        case .dashboard: DashboardView()
        case .music: MusicPage()
        case .calendar: CalendarPage()
        case .system: SystemPage()
        case .extensions: ExtensionsPane()
        case .shortcuts: ShortcutsPane()
        case .settings: SettingsPane()
        case .permissions: MainPermissionsPane()
        case .about: AboutPane()
        }
    }
}
