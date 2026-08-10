import AppKit
import CoreBluetooth
import EdithKit
import SwiftUI

struct NotchShelfRows: View {
    @AppStorage(AppStorageKeys.Notch.shelfEnabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.Notch.shelfOpenOnDrag, store: SharedDefaults.store) private
        var openOnDrag = true
    @AppStorage(AppStorageKeys.Notch.shelfOpenOnHover, store: SharedDefaults.store) private
        var openOnHover = true
    @AppStorage(AppStorageKeys.Notch.shelfRequireOption, store: SharedDefaults.store) private
        var requireOption =
        false
    @AppStorage(AppStorageKeys.Notch.shelfKeepDuration, store: SharedDefaults.store) private
        var keepDuration =
        "forever"
    @AppStorage(AppStorageKeys.Notch.shelfRemoveAfterDragOut, store: SharedDefaults.store)
    private var removeAfterDragOut = true
    @AppStorage(AppStorageKeys.Notch.shelfShowOnExternal, store: SharedDefaults.store)
    private var showOnExternal = true
    @AppStorage(AppStorageKeys.Notch.shelfHaptics, store: SharedDefaults.store) private
        var haptics = true
    @AppStorage(AppStorageKeys.Notch.shelfShowMusic, store: SharedDefaults.store) private
        var showMusic = true
    @AppStorage(AppStorageKeys.Notch.alertsEnabled, store: SharedDefaults.store) private
        var showAlerts = true
    @AppStorage(AppStorageKeys.Notch.alertAudio, store: SharedDefaults.store) private
        var alertAudio = true
    @AppStorage(AppStorageKeys.Notch.alertPower, store: SharedDefaults.store) private
        var alertPower = true
    @AppStorage(AppStorageKeys.Notch.alertBattery, store: SharedDefaults.store) private
        var alertBattery = true
    @AppStorage(AppStorageKeys.Notch.alertBluetooth, store: SharedDefaults.store) private
        var alertBluetooth =
        false
    @AppStorage(AppStorageKeys.Notch.audioMixerEnabled, store: SharedDefaults.store) private
        var audioMixer =
        false
    @State private var bluetoothAuthorization = CBManager.authorization

    var body: some View {
        Group {
            Section {
                Toggle("Open when dragging near the notch", isOn: $openOnDrag)
                    .pointerCursor()
                Text("The island slides out mid-drag so you can drop without clicking first.")
                    .settingsCaption()
                Toggle("Open on hover", isOn: $openOnHover)
                    .pointerCursor()
                Text("Expand when the mouse rests on the notch, without a drag.")
                    .settingsCaption()
                Toggle(isOn: $requireOption) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Require \u{2325} to trigger")
                        InfoDot(
                            "Only expand - on drag or on hover - while you're holding Option. Keeps accidental passes over the notch from opening it."
                        )
                    }
                }
                .pointerCursor()
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                Picker(selection: $keepDuration) {
                    Text("Forever").tag("forever")
                    Text("1 hour").tag("oneHour")
                    Text("1 day").tag("oneDay")
                    Text("1 week").tag("oneWeek")
                    Text("1 month").tag("oneMonth")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Keep items for")
                        InfoDot(
                            "Parked files auto-delete after this long. They're copies - originals are never touched."
                        )
                    }
                }
                .pointerCursor()
                Toggle("Remove after dragging out", isOn: $removeAfterDragOut)
                    .pointerCursor()
                Text("Treats the shelf as a hand-off tray rather than storage.")
                    .settingsCaption()
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                Toggle("Show what's playing", isOn: $showMusic)
                    .pointerCursor()
                Text(
                    "Album art and a live equalizer hug the notch while music plays in the library, Spotify, or Apple Music."
                )
                .settingsCaption()
                Toggle("Notch alerts", isOn: $showAlerts)
                    .pointerCursor()
                Text(
                    "Drops a brief card from the notch. Alerts that arrive while the notch is open queue up and show after it closes."
                )
                .settingsCaption()
                if showAlerts {
                    Toggle("Audio output changes", isOn: $alertAudio)
                        .pointerCursor()
                    Toggle("Power plugged / unplugged", isOn: $alertPower)
                        .pointerCursor()
                    Toggle("Battery low", isOn: $alertBattery)
                        .pointerCursor()
                    Toggle("Bluetooth connect / disconnect", isOn: $alertBluetooth)
                        .pointerCursor()
                    if alertBluetooth,
                        bluetoothAuthorization == .denied
                            || bluetoothAuthorization == .restricted
                    {
                        Button("Open Bluetooth Privacy Settings...") {
                            NSWorkspace.shared.open(
                                URL(
                                    string:
                                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
                                )!)
                        }
                        .pointerCursor()
                    }
                }
                Toggle("Per-app volume mixer (beta)", isOn: $audioMixer)
                    .pointerCursor()
                Text(
                    "Adds an Audio tab to set each app's volume. macOS 14.4+; asks for audio-recording permission the first time. Off by default."
                )
                .settingsCaption()
                Toggle("Show on external displays", isOn: $showOnExternal)
                    .pointerCursor()
                Text("Draws a small pill at the top of screens without a notch.")
                    .settingsCaption()
                Toggle("Haptic feedback", isOn: $haptics)
                    .pointerCursor()
                Text("A small trackpad tap when the shelf reacts.")
                    .settingsCaption()
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            bluetoothAuthorization = CBManager.authorization
        }
    }
}
