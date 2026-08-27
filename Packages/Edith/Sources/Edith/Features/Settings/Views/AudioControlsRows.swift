import EdithKit
import SwiftUI

struct AudioControlsRows: View {
    @AppStorage(AppStorageKeys.Audio.enabled, store: SharedDefaults.store) private var enabled = false
    @AppStorage(AppStorageKeys.Audio.preferredInputUID, store: SharedDefaults.store) private
        var preferredInputUID = ""
    @AppStorage(AppStorageKeys.Audio.lowerOnHeadphoneDisconnect, store: SharedDefaults.store)
    private var lowerOnDisconnect = true
    @AppStorage(AppStorageKeys.Audio.safeOutputPercent, store: SharedDefaults.store) private
        var safeOutputPercent = 25
    @AppStorage(AppStorageKeys.Audio.blockMusicLaunch, store: SharedDefaults.store) private
        var blockMusicLaunch = false
    @State private var snapshot = AudioDeviceSnapshot(
        devices: [], defaultInputUID: nil, defaultOutputUID: nil)
    @State private var errorMessage: String?

    var body: some View {
        Group {
            Section("Devices") {
                Picker("Preferred input", selection: preferredInputBinding) {
                    Text("Follow system default").tag("")
                    ForEach(snapshot.inputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !preferredInputUID.isEmpty,
                        !snapshot.inputs.contains(where: { $0.uid == preferredInputUID })
                    {
                        Text("Unavailable device").tag(preferredInputUID)
                    }
                }
                Text(
                    "Edith reapplies the preferred microphone when it returns, then restores your original input when Audio Controls is turned off."
                )
                .settingsCaption()

                Picker("System output", selection: outputBinding) {
                    if snapshot.outputs.isEmpty {
                        Text("No output available").tag("")
                    }
                    ForEach(snapshot.outputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Text("This switches the output for the whole Mac immediately.")
                    .settingsCaption()

                HStack {
                    Button("Refresh devices") { refresh() }
                    Spacer()
                    if let errorMessage {
                        Text(errorMessage).settingsCaption().foregroundStyle(.red)
                    }
                }
            }

            Section("Headphone safety") {
                Toggle(
                    "Lower speakers after headphones disconnect",
                    isOn: $lowerOnDisconnect.configured(
                        AppStorageKeys.Audio.lowerOnHeadphoneDisconnect)
                )
                Stepper(
                    "Safe speaker volume: \(safeOutputPercent)%",
                    value: $safeOutputPercent.configured(AppStorageKeys.Audio.safeOutputPercent),
                    in: 0...50, step: 5)
                    .disabled(!lowerOnDisconnect)
                Text(
                    "Edith lowers the newly selected non-headphone output once. It restores the previous level only when you have not changed it yourself."
                )
                .settingsCaption()
            }

            Section("Applications") {
                Toggle(
                    "Block Music from media-key launches",
                    isOn: $blockMusicLaunch.configured(AppStorageKeys.Audio.blockMusicLaunch)
                )
                Text(
                    "Only Music launches caused immediately by play, skip, or seek media keys are blocked. Manual launches remain untouched. If Edith's Music extension is enabled, the same key starts its player instead."
                )
                .settingsCaption()
                Text(
                    "Per-app output routes and volume use the existing Audio tab in Notch Shelf. Routes stay active while Audio Controls is enabled, even when the shelf is closed."
                )
                .settingsCaption()
                Text(
                    "Microphone muting remains in Mic Mute, so its shortcut and menu bar status stay the single source of truth."
                )
                .settingsCaption()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onAppear { refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in refresh() }
    }

    private var preferredInputBinding: Binding<String> {
        Binding(
            get: { preferredInputUID },
            set: { uid in
                preferredInputUID = uid
                if !uid.isEmpty { try? AudioDeviceOperations.setDefaultInput(uid: uid) }
                SharedDefaults.store.synchronize()
                IPC.post(IPC.Name.settingsChanged)
                refresh()
            })
    }

    private var outputBinding: Binding<String> {
        Binding(
            get: { snapshot.defaultOutputUID ?? "" },
            set: { uid in
                guard !uid.isEmpty else { return }
                do {
                    try AudioDeviceOperations.setDefaultOutput(uid: uid)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
                IPC.post(IPC.Name.settingsChanged)
                refresh()
            })
    }

    private func refresh() {
        do {
            snapshot = try AudioDeviceOperations.snapshot()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
