import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct PresenterRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.Presenter.enabled, store: SharedDefaults.store) private
        var presenterEnabled =
        false
    @AppStorage(AppStorageKeys.Presenter.mode, store: SharedDefaults.store) private
        var presenterMode = false
    @AppStorage(AppStorageKeys.Presenter.autoEnabled, store: SharedDefaults.store) private
        var autoEnabled = false
    @AppStorage(AppStorageKeys.Presenter.hideMenuBarNumbers, store: SharedDefaults.store)
    private var hideMenuBarNumbers = false
    @AppStorage(AppStorageKeys.Presenter.detectRecording, store: SharedDefaults.store)
    private var detectRecording = true
    @AppStorage(AppStorageKeys.Presenter.detectScreenSharing, store: SharedDefaults.store)
    private var detectScreenSharing = true
    @AppStorage(AppStorageKeys.Presenter.detectMirroring, store: SharedDefaults.store)
    private var detectMirroring = true
    @AppStorage(AppStorageKeys.Presenter.askJev, store: SharedDefaults.store)
    private var askJev = false
    private var jevConfigured: Bool { presentation.state.jevConfigured }

    var body: some View {
        SettingsIssueSection()
        Section {
            Toggle(isOn: $presenterMode.notifyingSettingsChange()) {
                Text("Manual presenter mode")
                Text(
                    "Blurs the details you pick below, everywhere in Edith, until you turn it off.")
            }
            SettingsShortcutRow(
                keyPrefix: "presenterHotKey", defaultLabel: "⇧⌥⌘P",
                purpose: "Turns presenter mode on or off from any app.")
        } header: {
            Text("Presenter mode")
        } footer: {
            Text("Turn it on before you share your screen. Apps outside Edith are never changed.")
                .settingsCaption()
        }

        Section {
            ForEach(PresenterPrivacy.listed) { category in
                PresenterPrivacySettingToggle(category: category)
            }
        } header: {
            Text("What to blur")
        }

        Section {
            Toggle(isOn: $autoEnabled.notifyingSettingsChange()) {
                Text("Auto presenter mode")
                Text("Turns presenter mode on by itself when your screen is shared or recorded.")
            }
            Group {
                Toggle(isOn: $hideMenuBarNumbers.notifyingSettingsChange()) {
                    Text("Hide menu bar numbers")
                    Text("Hides usage percentages in the menu bar while presenting.")
                }
                Toggle(isOn: $detectRecording.notifyingSettingsChange()) {
                    Text("Detect screen recordings")
                    Text("Includes QuickTime and Shift-Command-5 recordings.")
                }
                Toggle(isOn: $detectScreenSharing.notifyingSettingsChange()) {
                    Text("Detect macOS Screen Sharing")
                    Text("Includes Screen Sharing and Remote Management sessions.")
                }
                Toggle(isOn: $detectMirroring.notifyingSettingsChange()) {
                    Text("Count mirrored displays")
                    Text("Includes mirroring to a projector, TV or AirPlay.")
                }
                Toggle(isOn: $askJev.notifyingSettingsChange()) {
                    Text("Ask Jev about shared screens")
                    Text(
                        jevConfigured
                            ? "When no rule matches during a call, Jev checks the window titles."
                            : "Save a Jev key in the Jev settings to use this.")
                }
                .disabled(!jevConfigured)
            }
            .disabled(!autoEnabled)
            SettingsRow(
                "Screen Recording access",
                subtitle: "Optional. Lets detection read share window titles. Nothing is recorded."
            ) {
                Button("Open Settings") { presentation.perform("screenRecording") }
                    .buttonStyle(.edith(.secondary))
                    .disabled(!presentation.active)
            }
        } header: {
            Text("Auto detection")
        } footer: {
            Text(
                "Without Screen Recording access, detection uses app and window position instead. Asking Jev sends the owner, title and size of up to 25 on-screen windows to TypeSafe, so they leave this Mac."
            )
            .settingsCaption()
        }
    }
}

struct PresenterPrivacySettingToggle: View {
    let category: PresenterPrivacy
    @AppStorage private var stored: Bool

    init(category: PresenterPrivacy) {
        self.category = category
        _stored = AppStorage(
            wrappedValue: category.fallback, category.storageKey, store: SharedDefaults.store)
    }

    var body: some View {
        Toggle(isOn: $stored.notifyingSettingsChange()) {
            Text(category.title)
            Text(category.summary)
        }
    }
}

struct PresenterPrivacyQuickToggle: View {
    let category: PresenterPrivacy
    @AppStorage private var stored: Bool
    @State private var hovering = false

    init(category: PresenterPrivacy) {
        self.category = category
        _stored = AppStorage(
            wrappedValue: category.fallback, category.storageKey, store: SharedDefaults.store)
    }

    var body: some View {
        Button {
            storedBinding.wrappedValue.toggle()
        } label: {
            HStack(spacing: UIScale.pt(12)) {
                Text(category.title)
                    .font(.system(size: UIScale.pt(12.5)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: storedBinding)
                    .labelsHidden()
                    .toggleStyle(.edithSwitch)
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(8))
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel(category.title)
        .onHover { hovering = $0 }
    }

    private var storedBinding: Binding<Bool> {
        $stored.notifyingSettingsChange()
    }
}
