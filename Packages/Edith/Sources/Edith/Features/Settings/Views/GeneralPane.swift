import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct SettingsPane: View {
    enum Tab: String, CaseIterable {
        case general, permissions, shortcuts, terminal, icloud, updates
        var label: String {
            switch self {
            case .general: return "General"
            case .permissions: return "Permissions"
            case .shortcuts: return "Shortcuts"
            case .terminal: return "Terminal"
            case .icloud: return "iCloud"
            case .updates: return "Updates"
            }
        }
    }

    let updater: UpdaterModel
    @AppStorage(AppStorageKeys.General.settingsTab, store: SharedDefaults.store) private
        var tabRaw =
        Tab.general.rawValue
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: tabRaw) ?? .general },
            set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            PageHeader("Settings")
            Group {
                switch tab.wrappedValue {
                case .general: GeneralPane()
                case .permissions: PermissionsPane()
                case .shortcuts: ShortcutsSettingsPane()
                case .terminal: TerminalSettingsPane()
                case .icloud: ICloudPane()
                case .updates: UpdatesPane(updater: updater)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .toolbar {
            ToolbarItem(placement: .principal) {
                LiquidTabPicker(items: Tab.allCases, label: \.label, selection: tab)
            }
        }
        .onAppear {
            if automaticActionsEnabled {
                tabRaw =
                    MainNavigationFallback.resolve(
                        mainWindowSection: MainDestination.settings.rawValue, settingsTab: tabRaw
                    ).settingsTab
            }
        }
    }
}

private struct UpdatesPane: View {
    let updater: UpdaterModel
    @State private var showingSchedule = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private var dark: Bool { scheme == .dark }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var automaticDownloads: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.automaticallyDownloadsUpdates = $0 })
    }

    var body: some View {
        Group {
            if updater.updaterAvailable {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                        SkinCard(title: "Version", dark: dark) {
                            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                                LabeledContent("Current version") {
                                    Text(currentVersion)
                                        .foregroundStyle(DashSkin.inkSoft(dark))
                                }
                                LabeledContent("Last checked") {
                                    if let date = updater.lastUpdateCheckDate {
                                        Text(
                                            date,
                                            format: .dateTime.year().month().day().hour().minute()
                                        )
                                        .foregroundStyle(DashSkin.inkSoft(dark))
                                    } else {
                                        Text("Never")
                                            .foregroundStyle(DashSkin.inkSoft(dark))
                                    }
                                }
                                Button("Check for Updates") {
                                    updater.checkForUpdates()
                                }
                                .disabled(!updater.canCheckForUpdates)
                                .pointerCursor()
                            }
                            .foregroundStyle(DashSkin.ink(dark))
                        }
                        SkinCard(title: "Updates", dark: dark) {
                            Toggle("Automatic updates", isOn: automaticDownloads)
                                .pointerCursor()
                                .foregroundStyle(DashSkin.ink(dark))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    TapGesture().modifiers(.command).onEnded {
                                        showingSchedule = true
                                    }
                                )
                                .sheet(isPresented: $showingSchedule) {
                                    UpdateSchedulePanel(updater: updater)
                                }
                                .accessibilityHint(
                                    "Command-click to configure the check schedule and see history")
                        }
                    }
                    .pageContent(compact)
                    .padding(.top, UIScale.pt(16))
                }
                .background(DashSkin.paper(dark))
            } else {
                Text("Updates are unavailable in this build")
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DashSkin.paper(dark))
            }
        }
    }
}

struct GeneralPane: View {
    @AppStorage(AppStorageKeys.General.appearance, store: SharedDefaults.store) private
        var appearance = "system"
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.General.lastPaletteTheme, store: SharedDefaults.store) private
        var lastPaletteTheme =
        "blue"
    @AppStorage(AppStorageKeys.General.showDockIcon, store: SharedDefaults.store) private
        var showDockIcon = true
    @AppStorage(AppStorageKeys.General.mainWindowSection, store: SharedDefaults.store) private
        var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage(AppStorageKeys.General.settingsTab, store: SharedDefaults.store) private
        var settingsTab =
        SettingsPane.Tab.general.rawValue
    @State private var grantedPermissions: [ExtensionPermission: Bool] = [:]
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                SkinCard(title: "Appearance", dark: dark) {
                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        Picker("Appearance", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pointerCursor()
                        .onChange(of: appearance) { _, value in applyAppearance(value) }

                        LabeledContent("Theme") {
                            HStack(spacing: UIScale.pt(10)) {
                                Toggle(
                                    "Use accent",
                                    isOn: Binding(
                                        get: { themeName == "accent" },
                                        set: { themeName = $0 ? "accent" : lastPaletteTheme })
                                )
                                .toggleStyle(.switch)
                                .pointerCursor()
                                ForEach(themePalette, id: \.name) { entry in
                                    swatch(entry.name, color: entry.color)
                                }
                            }
                            .opacity(themeName == "accent" ? 0.5 : 1)
                        }
                    }
                    .foregroundStyle(DashSkin.ink(dark))
                }

                SkinCard(
                    title: "Window",
                    note: "Features are turned on and off from the Extensions page.", dark: dark
                ) {
                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        Toggle("Show Dock icon", isOn: $showDockIcon)
                            .pointerCursor()
                            .onChange(of: showDockIcon) { _, on in
                                NSApp.setActivationPolicy(on ? .regular : .accessory)
                            }
                        LabeledContent {
                            HotKeyRecorderControl(keyPrefix: "hotKey", defaultLabel: "⌥⌘E")
                        } label: {
                            HStack(spacing: UIScale.pt(6)) {
                                Text("Panel shortcut")
                                InfoDot(
                                    "The keyboard shortcut that opens Edith's menu bar panel, from anywhere."
                                )
                            }
                        }
                    }
                    .foregroundStyle(DashSkin.ink(dark))
                }

                SkinCard(
                    title: "Access", note: "Every permission Edith can ask for, in one place.",
                    dark: dark
                ) {
                    Button {
                        settingsTab = SettingsPane.Tab.permissions.rawValue
                    } label: {
                        LabeledContent("Permissions") {
                            HStack(spacing: UIScale.pt(6)) {
                                Text(permissionSummary)
                                    .foregroundStyle(DashSkin.inkSoft(dark))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: UIScale.pt(10)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                        }
                        .foregroundStyle(DashSkin.ink(dark))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                SkinCard(title: "Welcome tour", dark: dark) {
                    Button("Show welcome tour") {
                        SharedDefaults.store.removeObject(forKey: OnboardingFlow.completionKey)
                        OnboardingWindow.open()
                    }
                    .pointerCursor()
                }
            }
            .pageContent(compact)
            .padding(.top, UIScale.pt(16))
        }
        .background(DashSkin.paper(dark))
        .onAppear {
            if automaticActionsEnabled { refreshPermissionState() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if automaticActionsEnabled { refreshPermissionState() }
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            if automaticActionsEnabled {
                grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
            }
        }
    }

    private var enabledExtensionPermissions: Set<ExtensionPermission> {
        let enabledEntries = ExtensionRegistry.entries.filter {
            SharedDefaults.store.bool(forKey: $0.defaultsKey)
        }
        return Set(
            enabledEntries.flatMap { $0.requiredPermissions + $0.optionalPermissions })
    }

    private var permissionSummary: String {
        let permissions = enabledExtensionPermissions
        guard !permissions.isEmpty else { return "No enabled extension needs access" }
        let granted = permissions.filter { grantedPermissions[$0] == true }.count
        return "\(granted) of \(permissions.count) granted"
    }

    private func refreshPermissionState() {
        grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
        IPC.post(IPC.Name.requestPermissionsRefresh)
    }

    private func swatch(_ name: String, color: Color) -> some View {
        Button {
            themeName = name
            lastPaletteTheme = name
        } label: {
            ZStack {
                Circle().fill(color).frame(width: UIScale.pt(20), height: UIScale.pt(20))
                if themeName == name {
                    Image(systemName: "checkmark")
                        .font(.system(size: UIScale.pt(9), weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
