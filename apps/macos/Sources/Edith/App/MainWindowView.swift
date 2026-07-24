import AppKit
import EdithKit
import SwiftUI

enum MainDestination: String, CaseIterable, Identifiable {
    case home, dashboard, music, calendar, system
    case extensions, settings, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .dashboard: return "Agent Usage"
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .system: return "System"
        case .extensions: return "Extensions"
        case .settings: return "Settings"
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
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }

    static let homeItems: [MainDestination] = [.home, .dashboard, .music, .calendar, .system]
    static let appItems: [MainDestination] = [
        .extensions, .settings, .about,
    ]

    static func resolve(_ raw: String) -> MainDestination {
        MainDestination(rawValue: raw) ?? .home
    }

    var usesPaperBackground: Bool { Self.homeItems.contains(self) }
}

struct MainNavigationSelection: Equatable {
    let mainWindowSection: String
    let settingsTab: String
}

enum MainNavigationFallback {
    static func resolve(
        mainWindowSection: String, settingsTab: String
    ) -> MainNavigationSelection {
        if mainWindowSection == "shortcuts" {
            return MainNavigationSelection(mainWindowSection: "settings", settingsTab: "shortcuts")
        }
        let section = MainDestination(rawValue: mainWindowSection)?.rawValue ?? "home"
        let validSettingsTabs = ["general", "permissions", "shortcuts", "icloud", "updates"]
        let resolvedSettingsTab =
            validSettingsTabs.contains(settingsTab) ? settingsTab : "general"
        return MainNavigationSelection(
            mainWindowSection: section, settingsTab: resolvedSettingsTab)
    }
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
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Toggle sidebar (⌘B)")
            .keyboardShortcut("b", modifiers: .command)

            if sidebarOpen, width >= 130 {
                HStack(alignment: .center, spacing: 6) {
                    if let icon = Brand.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 17, height: 17)
                    }
                    Text("Edith")
                        .font(.system(size: 13, weight: .medium))
                        .tracking(-0.2)
                        .foregroundStyle(.secondary)
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
    let shortcutHint: String?
    let selectionNamespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(11)) {
                Image(systemName: item.icon)
                    .font(.system(size: UIScale.pt(14), weight: .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: UIScale.pt(22))
                Text(item.title)
                    .font(.system(size: UIScale.pt(13.5), weight: .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(size: UIScale.pt(11), weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, UIScale.pt(8))
            .padding(.horizontal, UIScale.pt(10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            ZStack {
                if hovering && !selected {
                    RoundedRectangle(cornerRadius: UIScale.pt(10), style: .continuous)
                        .fill(.primary.opacity(0.07))
                }
                if selected {
                    RoundedRectangle(cornerRadius: UIScale.pt(10), style: .continuous)
                        .fill(theme.opacity(0.16))
                        .matchedGeometryEffect(
                            id: "sidebarSelection", in: selectionNamespace, isSource: true)
                }
            }
        }
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
    @ObservedObject var updater = UpdaterModel()
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage("settingsTab", store: SharedDefaults.store) private var settingsTab = "general"
    @AppStorage("mainSidebarOpen", store: SharedDefaults.store) private var sidebarOpen = true
    @AppStorage("mainSidebarWidth", store: SharedDefaults.store) private var sidebarWidth = 230.0
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = false
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = false
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = false
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        false
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenterMode = false
    @AppStorage("presenterEnabled", store: SharedDefaults.store) private var presenterEnabled =
        false
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @AppStorage("presenterBlurMoney", store: SharedDefaults.store) private var presenterBlurMoney =
        true
    @AppStorage("presenterBlurUsage", store: SharedDefaults.store) private var presenterBlurUsage =
        false
    @AppStorage("presenterBlurCalendar", store: SharedDefaults.store)
    private var presenterBlurCalendar = true
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("creditHidden", store: SharedDefaults.store) private var creditHidden = false
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0
    @AppStorage("EdithMainWindowFullScreen") private var windowFullScreen = false
    @State private var dragBaseWidth: Double?
    @State private var musicKeyMonitor: Any?
    @State private var windowKeyMonitor: Any?
    @State private var commandHintMonitor: Any?
    @State private var commandHintWork: DispatchWorkItem?
    @State private var showShortcutHints = false
    @State private var nav = NavStack()
    @State private var musicFolderPath = ""
    @State private var restoringHistory = false
    @State private var permissionsNeedAttention = PermissionsStatus.current
    @State private var presenterQuickActionsPresented = false
    @State private var hoveredPresenterQuickAction: String?
    @State private var keyboardCleanTrigger = 0
    @Namespace private var sidebarSelectionNamespace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: Color { themeColor(themeName) }

    private static let minSidebarWidth = 180.0
    private static let maxSidebarWidth = 320.0
    private static let defaultSidebarWidth = 230.0
    private static let trafficLightsInset = 94.0
    private static let chromeHeight = 31.0
    private static let fullScreenControlsInset = 12.0

    private var clampedSidebarWidth: Double {
        min(Self.maxSidebarWidth, max(Self.minSidebarWidth, sidebarWidth))
    }

    private var displaySidebarWidth: Double { UIScale.pt(clampedSidebarWidth) }

    private var destination: MainDestination {
        let requested = MainDestination.resolve(navigationSelection.mainWindowSection)
        return switch requested {
        case .dashboard: usageEnabled ? requested : .home
        case .music: musicEnabled ? requested : .home
        case .calendar: calendarEnabled ? requested : .home
        case .system: systemEnabled ? requested : .home
        default: requested
        }
    }

    private var navigationSelection: MainNavigationSelection {
        MainNavigationFallback.resolve(
            mainWindowSection: mainWindowSection, settingsTab: settingsTab)
    }

    private var currentLocation: String {
        if destination == .settings {
            return "settings/\(navigationSelection.settingsTab)"
        }
        if destination == .music, !musicFolderPath.isEmpty {
            return "music/\(musicFolderPath)"
        }
        return navigationSelection.mainWindowSection
    }

    private func navigate(to location: String) {
        restoringHistory = true
        let music = MainDestination.music.rawValue
        if location.hasPrefix("settings/") {
            settingsTab = String(location.dropFirst("settings/".count))
            mainWindowSection = MainDestination.settings.rawValue
        } else if location == music || location.hasPrefix(music + "/") {
            MusicRemote.shared.navigate(
                to: location.hasPrefix(music + "/")
                    ? String(location.dropFirst(music.count + 1)) : "")
            mainWindowSection = music
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
            let bandHeight = Self.chromeHeight + UIScale.pt(10)
            VStack(spacing: 0) {
                mainArea(bandHeight)
                if musicFooterVisible {
                    MusicFooter()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
            .overlay { MusicDetailOverlay() }
            .overlay(alignment: .topLeading) { chromeOverlay() }
            .animation(
                Motion.animation(Motion.glide, reduceMotion: reduceMotion),
                value: visibleHomeItems
            )
            .animation(
                Motion.animation(Motion.glide, reduceMotion: reduceMotion),
                value: footerVisible)
        }
        .background(historyShortcuts)
        .onExitCommand { InputFocus.resignEditing() }
        .onReceive(MusicRemote.shared.$folderPath) { musicFolderPath = $0 }
        .onChange(of: currentLocation) { _, location in
            if restoringHistory {
                restoringHistory = false
            } else {
                nav.record(location)
            }
        }
        .onAppear {
            applyNavigationFallback()
            installWindowKeys()
            installCommandHintMonitor()
            syncMusicResources()
            PresenterState.shared.syncEnabled(presenterEnabled)
            refreshPermissionsPill()
            if nav.entries.isEmpty { nav.record(currentLocation) }
        }
        .onChange(of: musicEnabled) { _, _ in syncMusicResources() }
        .onChange(of: presenterEnabled) { _, on in PresenterState.shared.syncEnabled(on) }
        .onDisappear {
            removeWindowKeys()
            removeCommandHintMonitor()
            removeMusicKeys()
            MusicRemote.shared.stop()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshPermissionsPill()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            permissionsNeedAttention = PermissionsStatus.current
        }
    }

    private func applyNavigationFallback() {
        let resolved = navigationSelection
        mainWindowSection = resolved.mainWindowSection
        settingsTab = resolved.settingsTab
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

    private func syncMusicResources() {
        if musicEnabled {
            MusicRemote.shared.start()
            installMusicKeys()
        } else {
            removeMusicKeys()
            MusicRemote.shared.stop()
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
                .frame(width: displaySidebarWidth, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            detailColumn(bandHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: detailCorner, bottomLeadingRadius: detailCorner,
                        style: .continuous)
                )
                .padding(.leading, sidebarOpen ? displaySidebarWidth : 0)
                .shadow(color: detailShadow, radius: UIScale.pt(18), x: -6, y: 0)

            sidebarEdge
                .frame(maxHeight: .infinity)
                .offset(x: sidebarOpen ? displaySidebarWidth : 0)
                .opacity(sidebarOpen ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: sidebarOpen)
    }

    private func refreshPermissionsPill() {
        CalendarPermission.mirror()
        IPC.post(IPC.Name.requestPermissionsRefresh)
        permissionsNeedAttention = PermissionsStatus.current
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            permissionsNeedAttention = PermissionsStatus.current
        }
    }

    private func chromeOverlay() -> some View {
        let inset = windowFullScreen ? Self.fullScreenControlsInset : Self.trafficLightsInset
        return VStack(spacing: 0) {
            TitlebarChrome(
                height: Self.chromeHeight,
                width: sidebarOpen ? max(displaySidebarWidth - inset, 60) : UIScale.pt(200))
            Spacer(minLength: 0)
        }
        .padding(.leading, inset)
        .ignoresSafeArea(edges: .top)
    }

    private func band(_ color: Color, height: CGFloat) -> some View {
        color
            .frame(height: height)
            .allowsHitTesting(false)
    }

    private func detailColumn(_ bandHeight: CGFloat) -> some View {
        GeometryReader { geo in
            VStack(spacing: UIScale.pt(0)) {
                band(
                    destination.usesPaperBackground
                        ? DashSkin.paper(scheme == .dark) : Color(nsColor: .windowBackgroundColor),
                    height: bandHeight)
                detail
                    .tint(theme)
            }
            .environment(\.compactLayout, geo.size.width < UIScale.pt(640))
        }
    }

    private var footerVisible: Bool {
        systemEnabled || presenterEnabled || permissionsNeedAttention || updater.updateReady != nil
    }

    private func sidebar(_ bandHeight: CGFloat) -> some View {
        ZStack {
            SidebarMaterial()
            VStack(spacing: UIScale.pt(0)) {
                band(.clear, height: bandHeight)
                VStack(spacing: UIScale.pt(0)) {
                    sidebarList
                    if footerVisible {
                        Divider()
                        sidebarFooter
                    }
                    credit
                        .padding(.vertical, UIScale.pt(8))
                }
            }
        }
    }

    private var sidebarList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                ForEach(visibleHomeItems) { item in
                    SidebarNavRow(
                        item: item, selected: destination == item, theme: theme,
                        shortcutHint: shortcutHint(for: item),
                        selectionNamespace: sidebarSelectionNamespace
                    ) {
                        mainWindowSection = item.rawValue
                    }
                }
                Text("App")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.top, UIScale.pt(14))
                    .padding(.bottom, UIScale.pt(4))
                ForEach(MainDestination.appItems) { item in
                    SidebarNavRow(
                        item: item, selected: destination == item, theme: theme,
                        shortcutHint: shortcutHint(for: item),
                        selectionNamespace: sidebarSelectionNamespace
                    ) {
                        mainWindowSection = item.rawValue
                    }
                }
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.top, UIScale.pt(8))
        }
        .frame(maxHeight: .infinity)
        .animation(
            Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: destination
        )
        .animation(
            Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: showShortcutHints)
    }

    private var visibleHomeItems: [MainDestination] {
        MainDestination.homeItems.filter { item in
            switch item {
            case .dashboard: usageEnabled
            case .music: musicEnabled
            case .calendar: calendarEnabled
            case .system: systemEnabled
            default: true
            }
        }
    }

    private var navigableItems: [MainDestination] {
        visibleHomeItems + MainDestination.appItems
    }

    private func shortcutHint(for item: MainDestination) -> String? {
        guard showShortcutHints else { return nil }
        let items = navigableItems
        guard let index = items.firstIndex(of: item) else { return nil }
        if index < WindowKeyCommand.directSelectLimit { return "⌘\(index + 1)" }
        return index == items.count - 1 ? "⌘9" : nil
    }

    private func installWindowKeys() {
        guard windowKeyMonitor == nil else { return }
        windowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let code = event.keyCode
            let mods = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                guard
                    let command = WindowKeyCommand.resolve(
                        characters: characters, keyCode: code, modifiers: mods)
                else { return false }
                if let next = WindowZoom.adjusted(zoom, for: command) {
                    zoom = next
                    return true
                }
                let items = navigableItems
                guard
                    let index = WindowKeyCommand.resolvedIndex(
                        for: command, count: items.count,
                        current: items.firstIndex(of: destination) ?? 0)
                else { return false }
                mainWindowSection = items[index].rawValue
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeWindowKeys() {
        if let monitor = windowKeyMonitor {
            NSEvent.removeMonitor(monitor)
            windowKeyMonitor = nil
        }
    }

    private func installCommandHintMonitor() {
        guard commandHintMonitor == nil else { return }
        commandHintMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let commandDown = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated {
                if commandDown {
                    guard commandHintWork == nil, !showShortcutHints else { return }
                    let work = DispatchWorkItem {
                        showShortcutHints = true
                        commandHintWork = nil
                    }
                    commandHintWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                } else {
                    commandHintWork?.cancel()
                    commandHintWork = nil
                    showShortcutHints = false
                }
            }
            return event
        }
    }

    private func removeCommandHintMonitor() {
        commandHintWork?.cancel()
        commandHintWork = nil
        if let monitor = commandHintMonitor {
            NSEvent.removeMonitor(monitor)
            commandHintMonitor = nil
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: UIScale.pt(8)) {
            if let version = updater.updateReady {
                updateReadyPill(version)
            }
            if systemEnabled || presenterEnabled {
                quickActions
            }
            if permissionsNeedAttention {
                permissionsPill
            }
        }
        .padding(UIScale.pt(10))
    }

    private func updateReadyPill(_ version: String) -> some View {
        Button {
            updater.checkForUpdates()
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Update ready")
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                Text("v\(version)")
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    .opacity(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DashSkin.sage)
            .padding(.horizontal, UIScale.pt(9))
            .frame(height: UIScale.pt(28))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Show update options")
    }

    @ViewBuilder
    private var quickActions: some View {
        let tiles = [
            quickActionTile(
                icon: "keyboard", title: "Clean keys", active: false,
                trigger: keyboardCleanTrigger,
                help: "Lock the keyboard so you can wipe it"
            ) {
                keyboardCleanTrigger += 1
                IPC.post(IPC.Name.requestKeyboardClean)
            },
            quickActionTile(
                icon: preventSleep ? "moon.zzz.fill" : "moon.zzz", title: "Keep awake",
                active: preventSleep, trigger: preventSleep ? 1 : 0,
                help: "Keep this Mac from sleeping until turned off"
            ) {
                preventSleep.toggle()
            },
        ]
        VStack(spacing: UIScale.pt(8)) {
            if systemEnabled {
                if clampedSidebarWidth < 220 {
                    tiles[0]; tiles[1]
                } else {
                    HStack(spacing: UIScale.pt(8)) {
                        tiles[0]; tiles[1]
                    }
                }
            }
            if presenterEnabled {
                presenterQuickActionTile
            }
        }
    }

    private var presenterQuickActionTile: some View {
        HStack(spacing: UIScale.pt(0)) {
            Button {
                setPresenterMode(!presenterMode)
            } label: {
                VStack(spacing: UIScale.pt(4)) {
                    Image(systemName: "theatermasks.fill")
                        .font(.system(size: UIScale.pt(14)))
                        .symbolEffect(.bounce, value: presenterMode)
                    Text("Presenter mode")
                        .font(.system(size: UIScale.pt(10), weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UIScale.pt(8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Blur sensitive numbers and track names everywhere in Edith")

            Rectangle()
                .fill(presenterMode ? Color.white.opacity(0.24) : Color.primary.opacity(0.08))
                .frame(width: UIScale.pt(1), height: UIScale.pt(28))

            Button {
                presenterQuickActionsPresented.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .symbolEffect(.bounce, value: presenterQuickActionsPresented)
                    .frame(width: UIScale.pt(30), height: UIScale.pt(46))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Choose what Presenter mode blurs")
            .popover(isPresented: $presenterQuickActionsPresented, arrowEdge: .leading) {
                presenterQuickActionsPopover
            }
        }
        .foregroundStyle(presenterMode ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .background(
            presenterMode ? AnyShapeStyle(theme) : AnyShapeStyle(.thinMaterial),
            in: RoundedRectangle(cornerRadius: UIScale.pt(9))
        )
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }

    private var presenterQuickActionsPopover: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            Text("Presenter mode")
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .padding(.bottom, UIScale.pt(10))
            presenterQuickActionToggle(
                "Presenter mode",
                isOn: Binding(get: { presenterMode }, set: { setPresenterMode($0) })
            )
            Divider()
            presenterQuickActionToggle("Blur music", isOn: $presenterBlurMusic)
            Divider()
            presenterQuickActionToggle("Blur cost figures", isOn: $presenterBlurMoney)
            Divider()
            presenterQuickActionToggle("Blur usage figures", isOn: $presenterBlurUsage)
            Divider()
            presenterQuickActionToggle("Blur calendar events", isOn: $presenterBlurCalendar)
        }
        .padding(UIScale.pt(14))
        .frame(width: UIScale.pt(250))
    }

    private func setPresenterMode(_ on: Bool) {
        presenterMode = on
        if !on { IPC.post(IPC.Name.presenterPauseAuto) }
    }

    private func presenterQuickActionToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: UIScale.pt(12)) {
            Text(title)
                .font(.system(size: UIScale.pt(12.5)))
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(8))
        .background(
            hoveredPresenterQuickAction == title ? Color.primary.opacity(0.06) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isOn.wrappedValue.toggle()
        }
        .onHover { hovering in
            if hovering {
                hoveredPresenterQuickAction = title
            } else if hoveredPresenterQuickAction == title {
                hoveredPresenterQuickAction = nil
            }
        }
        .pointerCursor()
    }

    private func quickActionTile(
        icon: String, title: String, active: Bool, trigger: Int, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: UIScale.pt(4)) {
                Image(systemName: icon)
                    .font(.system(size: UIScale.pt(14)))
                    .symbolEffect(.bounce, value: trigger)
                Text(title)
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(8))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(
                active ? AnyShapeStyle(theme) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: UIScale.pt(9))
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
            .frame(width: UIScale.pt(1))
            .overlay {
                Color.clear
                    .frame(width: UIScale.pt(9))
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
                                let base = dragBaseWidth ?? displaySidebarWidth
                                dragBaseWidth = base
                                sidebarWidth = min(
                                    Self.maxSidebarWidth,
                                    max(
                                        Self.minSidebarWidth,
                                        (base + value.translation.width) / UIScale.current))
                            }
                            .onEnded { _ in dragBaseWidth = nil }
                    )
                    .onTapGesture(count: 2) { sidebarWidth = Self.defaultSidebarWidth }
            }
    }

    @ViewBuilder
    private var credit: some View {
        if !creditHidden {
            HStack(spacing: UIScale.pt(3)) {
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
                        .font(.system(size: UIScale.pt(8), weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                }
                .buttonStyle(HoverButtonStyle())
                .help("Hide this")
            }
            .font(.system(size: UIScale.pt(10)))
            .padding(.horizontal, UIScale.pt(8))
            .frame(maxWidth: .infinity)
        }
    }

    private var permissionsPill: some View {
        Button {
            settingsTab = SettingsPane.Tab.permissions.rawValue
            mainWindowSection = MainDestination.settings.rawValue
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Permissions need attention")
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, UIScale.pt(8))
            .frame(height: UIScale.pt(26))
            .background(
                Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
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
        case .settings: SettingsPane(updater: updater)
        case .about: AboutPane()
        }
    }
}
