import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct PresenterRows: View {
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
    @State private var jevConfigured = PresenterJevClient.configured() != nil

    var body: some View {
        Group {
            Section {
                Toggle(
                    isOn: $presenterMode.notifyingSettingsChange()
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Manual presenter mode")
                        InfoDot(
                            "Blurs the private details you choose, everywhere in Edith, "
                                + "until you turn it back off."
                        )
                    }
                }
                .onChange(of: presenterMode) {
                    _ = PresenterRuntimeOperationExecution.perform(
                        presenterMode ? .start : .stop)
                }
                ForEach(PresenterPrivacy.allCases) { category in
                    PresenterPrivacySettingToggle(category: category)
                }
            } header: {
                Text("Manual")
            }

            Section {
                Toggle(
                    isOn: $autoEnabled.notifyingSettingsChange()
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Auto presenter mode")
                        InfoDot(
                            "Automatically blurs Edith when your screen looks like it's being shared or recorded. Manual presenter mode keeps working independently."
                        )
                    }
                }
                Group {
                    Toggle(
                        isOn: $hideMenuBarNumbers.notifyingSettingsChange()
                    ) {
                        HStack(spacing: UIScale.pt(6)) {
                            Text("Hide menu bar numbers")
                            InfoDot(
                                "Replaces the usage percentages in the menu bar while presenting - they're visible in every screen share otherwise."
                            )
                        }
                    }
                    Toggle(
                        isOn: $detectRecording.notifyingSettingsChange()
                    ) {
                        HStack(spacing: UIScale.pt(6)) {
                            Text("Detect screen recordings")
                            InfoDot("Also blur during QuickTime or ⇧⌘5 recordings.")
                        }
                    }
                    Toggle(
                        isOn: $detectScreenSharing.notifyingSettingsChange()
                    ) {
                        HStack(spacing: UIScale.pt(6)) {
                            Text("Detect macOS Screen Sharing")
                            InfoDot(
                                "Also blur when someone views this Mac via Screen Sharing or Remote Management."
                            )
                        }
                    }
                    Toggle(
                        isOn: $detectMirroring.notifyingSettingsChange()
                    ) {
                        HStack(spacing: UIScale.pt(6)) {
                            Text("Mirrored display counts")
                            InfoDot(
                                "Blur when your display mirrors to a projector, TV, or AirPlay.")
                        }
                    }
                    Toggle(
                        isOn: $askJev.notifyingSettingsChange()
                    ) {
                        HStack(spacing: UIScale.pt(6)) {
                            Text("Ask Jev about shared screens")
                            InfoDot(
                                "When a call app is open and no built-in rule matches, Jev judges whether the on-screen windows show a shared screen. Needs a saved Jev key."
                            )
                        }
                    }
                    .disabled(!jevConfigured)
                }
                .disabled(!autoEnabled)
                .opacity(autoEnabled ? 1 : 0.5)
            } header: {
                Text("Auto detection")
            } footer: {
                Text(
                    "Recognizing a share's window title (e.g. \"Zoom share statusbar window\") needs Screen Recording access for Edith. Without it, detection falls back to coarser app + window position heuristics. Asking Jev also needs window titles: it sends the owner, title and size of up to 25 on-screen windows to TypeSafe, so they leave this Mac."
                )
                .font(.system(size: UIScale.pt(10)))
            }

            Section {
                Button("Open Screen Recording Settings…") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section {
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "presenterHotKey", defaultLabel: "⇧⌥⌘P")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Toggle hotkey")
                        InfoDot(
                            "Forces presenter mode on or off from anywhere - a manual escape hatch for when auto-detection guesses wrong."
                        )
                    }
                }
            } header: {
                Text("Shortcut")
            }
        }
        .disabled(!presenterEnabled)
        .opacity(presenterEnabled ? 1 : 0.5)
        .pageTask {
            jevConfigured = PresenterJevClient.configured() != nil
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: ExtensionSharedState.current?.notificationName ?? Notification.Name("unused"))
        ) { _ in
            jevConfigured = PresenterJevClient.configured() != nil
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
        Toggle(category.title, isOn: $stored.notifyingSettingsChange())
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
        .onHover { hovering = $0 }
    }

    private var storedBinding: Binding<Bool> {
        $stored.notifyingSettingsChange()
    }
}
