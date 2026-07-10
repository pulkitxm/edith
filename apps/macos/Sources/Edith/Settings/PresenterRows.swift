import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct PresenterRows: View {
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenterMode = false
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @AppStorage("presenterBlurMoney", store: SharedDefaults.store) private var presenterBlurMoney =
        true
    @AppStorage("presenterBlurCalendar", store: SharedDefaults.store)
    private var presenterBlurCalendar = true
    @AppStorage("presenterAutoEnabled", store: SharedDefaults.store) private var autoEnabled = false
    @AppStorage("presenterHideMenuBarNumbers", store: SharedDefaults.store)
    private var hideMenuBarNumbers = false
    @AppStorage("presenterDetectRecording", store: SharedDefaults.store)
    private var detectRecording = true
    @AppStorage("presenterDetectScreenSharing", store: SharedDefaults.store)
    private var detectScreenSharing = true
    @AppStorage("presenterDetectMirroring", store: SharedDefaults.store)
    private var detectMirroring = true

    var body: some View {
        Group {
            Section {
                Toggle(isOn: $presenterMode) {
                    HStack(spacing: 6) {
                        Text("Manual presenter mode")
                        InfoDot(
                            "Blurs sensitive numbers and track names everywhere in Edith until you turn it back off."
                        )
                    }
                }
                .pointerCursor()
                .onChange(of: presenterMode) {
                    if !presenterMode { IPC.post(IPC.Name.presenterPauseAuto) }
                }
                Toggle("Blur music", isOn: $presenterBlurMusic)
                    .pointerCursor()
                    .disabled(!presenterMode && !autoEnabled)
                Toggle("Blur cost and usage figures", isOn: $presenterBlurMoney)
                    .pointerCursor()
                    .disabled(!presenterMode && !autoEnabled)
                Toggle("Blur calendar events", isOn: $presenterBlurCalendar)
                    .pointerCursor()
                    .disabled(!presenterMode && !autoEnabled)
            } header: {
                Text("Manual")
            }

            Section {
                Toggle(isOn: $autoEnabled) {
                    HStack(spacing: 6) {
                        Text("Auto presenter mode")
                        InfoDot(
                            "Automatically blurs Edith when your screen looks like it's being shared or recorded. Manual presenter mode keeps working independently."
                        )
                    }
                }
                .pointerCursor()
                Group {
                    Toggle(isOn: $hideMenuBarNumbers) {
                        HStack(spacing: 6) {
                            Text("Hide menu bar numbers")
                            InfoDot(
                                "Replaces the usage percentages in the menu bar while presenting - they're visible in every screen share otherwise."
                            )
                        }
                    }
                    .pointerCursor()
                    Toggle(isOn: $detectRecording) {
                        HStack(spacing: 6) {
                            Text("Detect screen recordings")
                            InfoDot("Also blur during QuickTime or ⇧⌘5 recordings.")
                        }
                    }
                    .pointerCursor()
                    Toggle(isOn: $detectScreenSharing) {
                        HStack(spacing: 6) {
                            Text("Detect macOS Screen Sharing")
                            InfoDot(
                                "Also blur when someone views this Mac via Screen Sharing or Remote Management."
                            )
                        }
                    }
                    .pointerCursor()
                    Toggle(isOn: $detectMirroring) {
                        HStack(spacing: 6) {
                            Text("Mirrored display counts")
                            InfoDot(
                                "Blur when your display mirrors to a projector, TV, or AirPlay.")
                        }
                    }
                    .pointerCursor()
                }
                .disabled(!autoEnabled)
                .opacity(autoEnabled ? 1 : 0.5)
            } header: {
                Text("Auto detection")
            } footer: {
                Text(
                    "Recognizing a share's window title (e.g. \"Zoom share statusbar window\") needs Screen Recording access for Edith. Without it, detection falls back to coarser app + window position heuristics."
                )
                .font(.caption)
            }

            Section {
                Button("Open Screen Recording Settings…") {
                    NSWorkspace.shared.open(
                        URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                        )!)
                }
                .pointerCursor()
            }

            Section {
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "presenterHotKey", defaultLabel: "⇧⌥⌘P")
                } label: {
                    HStack(spacing: 6) {
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
    }
}
