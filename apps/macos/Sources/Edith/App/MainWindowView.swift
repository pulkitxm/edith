import AppKit
import EdithKit
import SwiftUI

enum MainSection: String, Identifiable {
    case dashboard, settings
    var id: String { rawValue }
}

enum SettingsDestination: String, CaseIterable, Identifiable {
    case usage, music, calendar, system, clipboard, focusDim, presenter, general, permissions,
        backup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: return "Usage"
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .system: return "System"
        case .clipboard: return "Clipboard"
        case .focusDim: return "Focus Dim"
        case .presenter: return "Presenter"
        case .general: return "General"
        case .permissions: return "Permissions"
        case .backup: return "Backup"
        }
    }

    var icon: String {
        switch self {
        case .usage: return "gauge.with.dots.needle.67percent"
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .system: return "switch.2"
        case .clipboard: return "doc.on.clipboard"
        case .focusDim: return "circle.lefthalf.filled"
        case .presenter: return "theatermasks.fill"
        case .general: return "gearshape"
        case .permissions: return "checkmark.shield"
        case .backup: return "icloud"
        }
    }

    static let modules: [SettingsDestination] = [
        .usage, .music, .calendar, .system, .clipboard, .focusDim, .presenter,
    ]
    static let app: [SettingsDestination] = [.general, .permissions, .backup]
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

            if sidebarOpen {
                HStack(alignment: .center, spacing: 7) {
                    if let icon = Brand.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 19, height: 19)
                    }
                    Text("Edith")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 200, height: height, alignment: .leading)
    }
}

struct MainWindowView: View {
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        "dashboard"
    @AppStorage("settingsSection", store: SharedDefaults.store) private var settingsSectionRaw =
        SettingsDestination.general.rawValue
    @AppStorage("mainSidebarOpen", store: SharedDefaults.store) private var sidebarOpen = true
    @AppStorage("mainSidebarWidth", store: SharedDefaults.store) private var sidebarWidth = 230.0
    @State private var dragBaseWidth: Double?
    @State private var permissionsNeedAttention = PermissionsStatus.current
    @Environment(\.colorScheme) private var scheme

    private var mainSelection: Binding<MainSection?> {
        Binding(
            get: { mainWindowSection == "settings" ? .settings : .dashboard },
            set: { mainWindowSection = $0 == .settings ? "settings" : "dashboard" })
    }

    private var settingsSelection: Binding<SettingsDestination?> {
        Binding(
            get: { SettingsDestination(rawValue: settingsSectionRaw) },
            set: { settingsSectionRaw = $0?.rawValue ?? SettingsDestination.general.rawValue })
    }

    var body: some View {
        GeometryReader { geo in
            let bandHeight = max(geo.safeAreaInsets.top, 28)
            HStack(spacing: 0) {
                if sidebarOpen {
                    sidebar(bandHeight)
                        .frame(width: sidebarWidth)
                }
                detailColumn(bandHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) { chromeOverlay(bandHeight) }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            IPC.post(IPC.Name.requestPermissionsRefresh)
            permissionsNeedAttention = PermissionsStatus.current
        }
    }

    private func chromeOverlay(_ bandHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            TitlebarChrome(height: min(bandHeight, 52))
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
                mainWindowSection == "settings"
                    ? Color(nsColor: .windowBackgroundColor) : DashSkin.paper(scheme == .dark),
                height: bandHeight)
            detail
        }
    }

    private func sidebar(_ bandHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            band(Color(nsColor: .windowBackgroundColor), height: bandHeight)
            VStack(spacing: 0) {
                sidebarList
                Divider()
                sidebarFooter
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .overlay(alignment: .trailing) { sidebarEdge }
    }

    @ViewBuilder
    private var sidebarList: some View {
        if mainWindowSection == "settings" {
            List(selection: settingsSelection) {
                Section("Extensions") {
                    ForEach(SettingsDestination.modules) { destination in
                        sidebarRow(destination.title, icon: destination.icon)
                            .tag(destination)
                    }
                }
                Section("App") {
                    ForEach(SettingsDestination.app) { destination in
                        sidebarRow(destination.title, icon: destination.icon)
                            .tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else {
            List(selection: mainSelection) {
                Section("Home") {
                    sidebarRow("Dashboard", icon: "chart.bar.fill")
                        .tag(MainSection.dashboard)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func sidebarRow(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .pointerCursor()
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
                                let base = dragBaseWidth ?? sidebarWidth
                                dragBaseWidth = base
                                sidebarWidth = min(320, max(180, base + value.translation.width))
                            }
                            .onEnded { _ in dragBaseWidth = nil }
                    )
            }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 6) {
            if mainWindowSection != "settings", permissionsNeedAttention {
                permissionsPill
            }
            if mainWindowSection == "settings" {
                sidebarFooterButton(title: "Back to Dashboard", icon: "chevron.left") {
                    mainWindowSection = "dashboard"
                }
            } else {
                sidebarFooterButton(title: "Settings", icon: "gearshape") {
                    mainWindowSection = "settings"
                }
            }
        }
        .padding(10)
    }

    private var permissionsPill: some View {
        Button {
            settingsSectionRaw = SettingsDestination.permissions.rawValue
            mainWindowSection = "settings"
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

    private func sidebarFooterButton(
        title: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverButtonStyle())
    }

    @ViewBuilder
    private var detail: some View {
        if mainWindowSection == "settings" {
            settingsDetail
        } else {
            DashboardView()
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch settingsSelection.wrappedValue ?? .general {
        case .usage: UsagePane()
        case .music: MusicPane()
        case .calendar: CalendarPane()
        case .system: SystemPane()
        case .clipboard: ClipboardPane()
        case .focusDim: FocusDimPane()
        case .presenter: PresenterPane()
        case .general: GeneralPane()
        case .permissions: MainPermissionsPane()
        case .backup: BackupPane()
        }
    }
}
