import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct SettingsPane: View {
    enum Tab: String, CaseIterable {
        case general, permissions, shortcuts, icloud, updates
        var label: String {
            switch self {
            case .general: return "General"
            case .permissions: return "Permissions"
            case .shortcuts: return "Shortcuts"
            case .icloud: return "iCloud"
            case .updates: return "Updates"
            }
        }
    }

    @ObservedObject var updater: UpdaterModel
    @AppStorage("settingsTab", store: SharedDefaults.store) private var tabRaw =
        Tab.general.rawValue

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: tabRaw) ?? .general },
            set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            Picker("", selection: tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .pointerCursor()
            .frame(maxWidth: UIScale.pt(320))
            .padding(.horizontal, UIScale.pt(20))
            .padding(.top, UIScale.pt(16))
            .padding(.bottom, UIScale.pt(12))
            Group {
                switch tab.wrappedValue {
                case .general: GeneralPane()
                case .permissions: PermissionsPane()
                case .shortcuts: ShortcutsSettingsPane()
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
            tabRaw =
                MainNavigationFallback.resolve(
                    mainWindowSection: MainDestination.settings.rawValue, settingsTab: tabRaw
                ).settingsTab
        }
    }
}

private struct UpdatesPane: View {
    @ObservedObject var updater: UpdaterModel

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
    private let licenseState = LicenseState()
    private let licenseCredentialStore = FileLicenseCredentialStore()
    @AppStorage("appearance", store: SharedDefaults.store) private var appearance = "system"
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("lastPaletteTheme", store: SharedDefaults.store) private var lastPaletteTheme =
        "blue"
    @AppStorage("showDockIcon", store: SharedDefaults.store) private var showDockIcon = true
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage("settingsTab", store: SharedDefaults.store) private var settingsTab =
        SettingsPane.Tab.general.rawValue
    @State private var grantedPermissions: [ExtensionPermission: Bool] = [:]
    @State private var licenseLabel = "Licensed"
    @State private var maskedLicenseKey = "EDITH-****-****-****-****"
    @State private var planAllowance: String?
    @State private var licenseError: String?
    @State private var deactivating = false

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

            Section {
                LabeledContent("License") {
                    VStack(alignment: .trailing, spacing: UIScale.pt(3)) {
                        Text(licenseLabel)
                            .foregroundStyle(.secondary)
                        Text(maskedLicenseKey)
                            .font(.system(size: UIScale.pt(10), design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let planAllowance {
                    LabeledContent("Plan") {
                        Text(planAllowance)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(
                    licenseError == nil ? "Deactivate" : "Retry Deactivation",
                    role: .destructive, action: deactivateLicense
                )
                .disabled(deactivating)
                .pointerCursor()
                if let licenseError {
                    Text(licenseError)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.red)
                }
            } header: {
                Text("License")
            } footer: {
                Text("Deactivation takes effect the next time Edith launches.")
                    .font(.system(size: UIScale.pt(10)))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear {
            refreshPermissionState()
            refreshLicenseState()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshPermissionState()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            grantedPermissions = ExtensionPermissionState.readGrantedPermissions()
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

    private func refreshLicenseState() {
        licenseLabel = licenseState.label ?? "Licensed"
        if let key = try? licenseState.licenseKey() {
            maskedLicenseKey = LicenseKeyFormatting.masked(key)
        }
        if let raw = ((try? licenseCredentialStore.read(.entitlement)) ?? nil),
            let payload = LicenseEntitlement.decodePayload(raw)
        {
            planAllowance = "\(payload.planId), up to \(payload.maxMachines) Macs"
        } else {
            planAllowance = nil
        }
    }

    private func deactivateLicense() {
        guard !deactivating else { return }
        deactivating = true
        Task {
            defer { deactivating = false }
            do {
                try await LicenseSession(credentialStore: licenseCredentialStore).deactivate()
            } catch {
                licenseError =
                    "This Mac could not be released, so nothing was removed. "
                    + "Check your connection and try again."
                return
            }
            do {
                try licenseState.deactivate()
            } catch {
                licenseError = "The license could not be removed from this Mac."
                return
            }
            licenseLabel = "Deactivated"
            maskedLicenseKey = "EDITH-****-****-****-****"
            planAllowance = nil
            licenseError = nil
        }
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
