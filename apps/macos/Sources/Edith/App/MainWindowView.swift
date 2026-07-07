import AppKit
import EdithKit
import SwiftUI

enum MainDestination: String, CaseIterable, Identifiable {
    case home, dashboard, music, calendar
    case extensions, usage, shortcuts, general, permissions, icloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .dashboard: return "Agent Usage"
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .extensions: return "Extensions"
        case .usage: return "Usage"
        case .shortcuts: return "Shortcuts"
        case .general: return "General"
        case .permissions: return "Permissions"
        case .icloud: return "iCloud"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .dashboard: return "chart.bar.fill"
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .extensions: return "puzzlepiece.extension"
        case .usage: return "gauge.with.dots.needle.67percent"
        case .shortcuts: return "command"
        case .general: return "gearshape"
        case .permissions: return "checkmark.shield"
        case .icloud: return "icloud"
        }
    }

    static let homeItems: [MainDestination] = [.home, .dashboard, .music, .calendar]
    static let appItems: [MainDestination] = [
        .extensions, .usage, .shortcuts, .general, .permissions, .icloud,
    ]

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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            selected
                ? AnyShapeStyle(theme)
                : hovering ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

struct MainWindowView: View {
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage("mainSidebarOpen", store: SharedDefaults.store) private var sidebarOpen = true
    @AppStorage("mainSidebarWidth", store: SharedDefaults.store) private var sidebarWidth = 230.0
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenterMode = false
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @ObservedObject private var musicRemote = MusicRemote.shared
    @State private var dragBaseWidth: Double?
    @State private var permissionsNeedAttention = PermissionsStatus.current
    @Environment(\.colorScheme) private var scheme

    private var theme: Color { themeColor(themeName) }

    private static let minSidebarWidth = 180.0
    private static let maxSidebarWidth = 320.0

    private var clampedSidebarWidth: Double {
        min(Self.maxSidebarWidth, max(Self.minSidebarWidth, sidebarWidth))
    }

    private var destination: MainDestination {
        MainDestination(rawValue: mainWindowSection) ?? .home
    }

    var body: some View {
        GeometryReader { geo in
            let bandHeight = max(geo.safeAreaInsets.top, 28)
            HStack(spacing: 0) {
                if sidebarOpen {
                    sidebar(bandHeight)
                        .frame(width: clampedSidebarWidth)
                }
                detailColumn(bandHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) { chromeOverlay(bandHeight) }
        }
        .onAppear {
            MusicRemote.shared.start()
            refreshPermissionsPill()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshPermissionsPill()
        }
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
            || (destination != .music && musicRemote.current != nil)
    }

    private func sidebar(_ bandHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            band(Color(nsColor: .windowBackgroundColor), height: bandHeight)
            VStack(spacing: 0) {
                openPanelRow
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
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
        .overlay(alignment: .trailing) { sidebarEdge }
    }

    private var sidebarList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MainDestination.homeItems) { item in
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
            if destination != .music {
                SidebarMiniPlayer(width: clampedSidebarWidth)
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

    private var openPanelRow: some View {
        Button {
            IPC.post(IPC.Name.openPanel)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text("Open Menu Bar Panel")
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .pointerCursor()
        .help("Open the Edith panel from the menu bar")
    }

    private var credit: some View {
        HStack(spacing: 3) {
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
        }
        .font(.system(size: 10))
        .frame(maxWidth: .infinity)
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
        case .extensions: ExtensionsPane()
        case .usage: UsagePane()
        case .shortcuts: ShortcutsPane()
        case .general: GeneralPane()
        case .permissions: MainPermissionsPane()
        case .icloud: ICloudPane()
        }
    }
}
