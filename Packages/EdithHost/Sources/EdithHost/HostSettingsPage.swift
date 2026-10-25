import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostSettingsPage: View {
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
        "home"
    @AppStorage(AppStorageKeys.General.settingsTab, store: SharedDefaults.store) private
        var settingsTab =
        "general"
    let marketplace: HostMarketplace?
    let permissions: HostPermissions
    var openPermissions: () -> Void = {}
    var showWelcome: (() -> Void)? = nil
    var panelShortcutChanged: () -> Void = {}
    var activation: (Bool) -> Void = { NSApp.setActivationPolicy($0 ? .regular : .accessory) }
    private var grantedPermissions: [HostPermission: Bool] { permissions.granted }

    init(
        marketplace: HostMarketplace? = nil, permissions: HostPermissions = HostPermissions(),
        defaults: UserDefaults = SharedDefaults.store,
        openPermissions: @escaping () -> Void = {}, showWelcome: (() -> Void)? = nil,
        panelShortcutChanged: @escaping () -> Void = {},
        activation: @escaping (Bool) -> Void = {
            NSApp.setActivationPolicy($0 ? .regular : .accessory)
        }
    ) {
        self.marketplace = marketplace; self.permissions = permissions;
        self.openPermissions = openPermissions
        self.showWelcome = showWelcome; self.panelShortcutChanged = panelShortcutChanged;
        self.activation = activation
        self.defaults = defaults
        _appearance = AppStorage(
            wrappedValue: "system", AppStorageKeys.General.appearance, store: defaults)
        _themeName = AppStorage(
            wrappedValue: "accent", AppStorageKeys.General.theme, store: defaults)
        _lastPaletteTheme = AppStorage(
            wrappedValue: "blue", AppStorageKeys.General.lastPaletteTheme, store: defaults)
        _showDockIcon = AppStorage(
            wrappedValue: true, AppStorageKeys.General.showDockIcon, store: defaults)
        _mainWindowSection = AppStorage(
            wrappedValue: "home", AppStorageKeys.General.mainWindowSection, store: defaults)
        _settingsTab = AppStorage(
            wrappedValue: "general", AppStorageKeys.General.settingsTab, store: defaults)
    }
    private let defaults: UserDefaults
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        Form {
            Section {
                Picker(
                    "Appearance",
                    selection: $appearance
                ) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, value in applyAppearance(value) }

                LabeledContent("Theme") {
                    WrapHStack(spacing: UIScale.pt(10)) {
                        Toggle(
                            "Use accent",
                            isOn: Binding(
                                get: { themeName == "accent" },
                                set: {
                                    $themeName
                                        .wrappedValue = $0 ? "accent" : lastPaletteTheme
                                })
                        )
                        .toggleStyle(.switch)
                        ForEach(themePalette, id: \.name) { entry in
                            swatch(entry.name, color: entry.color)
                        }
                    }
                }
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle(
                    "Show Dock icon",
                    isOn: $showDockIcon
                ).accessibilityLabel("Show Dock icon")
                    .onChange(of: showDockIcon) { _, on in
                        activation(on)
                    }
                LabeledContent {
                    HostHotKeyRecorder(
                        keyPrefix: "hotKey", defaultLabel: "⌥⌘E", defaults: defaults,
                        commit: panelShortcutChanged)
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
                    settingsTab = "permissions"
                    openPermissions()
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
                .buttonStyle(.edith(.borderless)).accessibilityLabel("Permissions")
                .accessibilityValue(permissionSummary)
            } header: {
                Text("Access")
            } footer: {
                Text("Every permission Edith can ask for, in one place.")
                    .font(.system(size: UIScale.pt(10)))
            }

            Section {
                Button("Show welcome tour") {
                    showWelcome?()
                }.disabled(showWelcome == nil)
            } header: {
                Text("Welcome tour")
            }

        }
        .edithForm()
        .navigationTitle("General")
        .pageTask { await permissions.refresh() }
    }

    private var enabledExtensionPermissions: Set<HostPermission> {
        guard let marketplace else { return [] }
        return Set(
            marketplace.entries.filter { marketplace.surfaceAvailability.activeIDs.contains($0.id) }
                .flatMap { $0.requiredPermissions + $0.optionalPermissions })
    }

    private var permissionSummary: String {
        let permissions = enabledExtensionPermissions
        guard !permissions.isEmpty else { return "No enabled extension needs access" }
        let granted = permissions.filter { grantedPermissions[$0] == true }.count
        return "\(granted) of \(permissions.count) granted"
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
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel("\(name.capitalized) theme")
        .accessibilityAddTraits(themeName == name ? .isSelected : AccessibilityTraits())
        .help("Use the \(name) theme")
    }
}
