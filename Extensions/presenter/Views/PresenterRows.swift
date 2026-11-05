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
        ControlSettingsIssueSection()
        Section {
            Toggle(isOn: $presenterMode.notifyingSettingsChange()) {
                PresenterRowLabel(
                    "Manual presenter mode",
                    detail:
                        "Blurs the details you pick below, everywhere in Edith, until you turn it off."
                )
            }
            LabeledContent {
                HotKeyRecorderControl(keyPrefix: "presenterHotKey", defaultLabel: "⇧⌥⌘P")
            } label: {
                PresenterRowLabel(
                    "Shortcut", detail: "Turns presenter mode on or off from any app.")
            }
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
                PresenterRowLabel(
                    "Auto presenter mode",
                    detail:
                        "Turns presenter mode on by itself when your screen is shared or recorded."
                )
            }
            Group {
                Toggle(isOn: $hideMenuBarNumbers.notifyingSettingsChange()) {
                    PresenterRowLabel(
                        "Hide menu bar numbers",
                        detail: "Hides usage percentages in the menu bar while presenting.")
                }
                Toggle(isOn: $detectRecording.notifyingSettingsChange()) {
                    PresenterRowLabel(
                        "Detect screen recordings",
                        detail: "Includes QuickTime and Shift-Command-5 recordings.")
                }
                Toggle(isOn: $detectScreenSharing.notifyingSettingsChange()) {
                    PresenterRowLabel(
                        "Detect macOS Screen Sharing",
                        detail: "Includes Screen Sharing and Remote Management sessions.")
                }
                Toggle(isOn: $detectMirroring.notifyingSettingsChange()) {
                    PresenterRowLabel(
                        "Count mirrored displays",
                        detail: "Includes mirroring to a projector, TV or AirPlay.")
                }
                Toggle(isOn: $askJev.notifyingSettingsChange()) {
                    PresenterRowLabel(
                        "Ask Jev about shared screens",
                        detail: jevConfigured
                            ? "When no rule matches during a call, Jev checks the window titles."
                            : "Save a Jev key in the Jev settings to use this.")
                }
                .disabled(!jevConfigured)
            }
            .disabled(!autoEnabled)
            LabeledContent {
                Button("Open Settings") { presentation.perform("screenRecording") }
                    .buttonStyle(.edith(.secondary))
                    .disabled(!presentation.active)
            } label: {
                PresenterRowLabel(
                    "Screen Recording access",
                    detail:
                        "Optional. Lets detection read share window titles. Nothing is recorded.")
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

struct PresenterRowLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(title)
            Text(detail).settingsCaption().fixedSize(horizontal: false, vertical: true)
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
            PresenterRowLabel(category.title, detail: category.summary)
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
                    .toggleStyle(.switch)
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
