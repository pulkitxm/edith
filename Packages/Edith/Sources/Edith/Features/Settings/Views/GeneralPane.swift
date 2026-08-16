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

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: tabRaw) ?? .general },
            set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            PageHeader(
                "Settings",
                accessory: {
                    Picker("", selection: tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .pointerCursor()
                    .frame(maxWidth: UIScale.pt(320), alignment: .leading)
                })
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
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
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
                Form {
                    Section {
                        LabeledContent("Current version") {
                            Text(currentVersion)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Last checked") {
                            if let date = updater.lastUpdateCheckDate {
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Never")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Check for Updates") {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)
                        .pointerCursor()
                    } header: {
                        Text("Version")
                    }

                    Section {
                        Toggle("Automatic updates", isOn: automaticDownloads)
                            .pointerCursor()
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
                    } header: {
                        Text("Updates")
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Updates are unavailable in this build")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Updates")
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

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Appearance")
            }

            Section {
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
            } header: {
                Text("Window")
            } footer: {
                Text("Features are turned on and off from the Extensions page.")
                    .font(.system(size: UIScale.pt(10)))
            }

            Section {
                Button {
                    settingsTab = SettingsPane.Tab.permissions.rawValue
                } label: {
                    LabeledContent("Permissions") {
                        HStack(spacing: UIScale.pt(6)) {
                            Text(permissionSummary)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: UIScale.pt(10)))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
            } header: {
                Text("Access")
            } footer: {
                Text("Every permission Edith can ask for, in one place.")
                    .font(.system(size: UIScale.pt(10)))
            }

            Section {
                Button("Show welcome tour") {
                    SharedDefaults.store.removeObject(forKey: OnboardingFlow.completionKey)
                    OnboardingWindow.open()
                }
                .pointerCursor()
            } header: {
                Text("Welcome tour")
            }

        }
        .formStyle(.grouped)
        .navigationTitle("General")
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
