import AppKit
import EdithKit
import SwiftUI

struct ExtensionsPane: View {
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = true
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = true
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        true
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
    @AppStorage("menuBarSystemStats", store: SharedDefaults.store) private var systemStats = false
    @AppStorage("notchShelfEnabled", store: SharedDefaults.store) private var notchShelfEnabled =
        false
    @AppStorage("clipboardEnabled", store: SharedDefaults.store) private var clipboardEnabled =
        false
    @AppStorage("focusDimEnabled", store: SharedDefaults.store) private var focusDimEnabled = false
    @AppStorage("micMuteEnabled", store: SharedDefaults.store) private var micMuteEnabled = false
    @AppStorage("colorPickerEnabled", store: SharedDefaults.store) private var colorPickerEnabled =
        false
    @State private var expanded: Set<String> = []

    var body: some View {
        Form {
            header(
                "usage", title: "Agent Usage", icon: "chart.bar.fill",
                subtitle: "Claude session and weekly limits, usage stats, and alerts.",
                enabled: $usageEnabled, group: "Agent")
            if expanded.contains("usage") { UsageRows() }

            header(
                "system", title: "System", icon: "switch.2",
                subtitle: "Running apps, prevent sleep, and the keyboard-cleaning lock.",
                enabled: $systemEnabled, group: "System")
            if expanded.contains("system") { SystemRows() }

            header(
                "systemStats", title: "CPU & Memory in menu bar", icon: "gauge.with.needle",
                subtitle: "Live CPU and memory readout as a menu bar item.",
                enabled: $systemStats)
            if expanded.contains("systemStats") { SystemStatsRows() }

            header(
                "micMute", title: "Mic Mute", icon: "mic.slash.fill",
                subtitle: "Mute every microphone system-wide with ⌘⇧M or the menu bar icon.",
                enabled: $micMuteEnabled, expandable: false)

            header(
                "music", title: "Music", icon: "music.note",
                subtitle: "Plays your local music folder, with media keys.",
                enabled: $musicEnabled, group: "Media")
            if expanded.contains("music") { MusicRows() }

            header(
                "calendar", title: "Calendar", icon: "calendar",
                subtitle: "Shows your schedule in the panel and the app.",
                enabled: $calendarEnabled, expandable: false)

            header(
                "notchShelf", title: "Notch Shelf", icon: "tray.and.arrow.down",
                subtitle: "File shelf, now playing, camera, and alerts around the notch.",
                enabled: $notchShelfEnabled)
            if expanded.contains("notchShelf") { NotchShelfRows() }

            header(
                "clipboard", title: "Clipboard", icon: "doc.on.clipboard",
                subtitle: "Clipboard history with instant paste.",
                enabled: $clipboardEnabled, group: "Utilities")
            if expanded.contains("clipboard") { ClipboardRows() }

            header(
                "focusDim", title: "Focus Dim", icon: "circle.lefthalf.filled",
                subtitle: "Dims everything behind your active app.",
                enabled: $focusDimEnabled)
            if expanded.contains("focusDim") { FocusDimRows() }

            header(
                "presenter", title: "Presenter", icon: "theatermasks.fill",
                subtitle: "Blurs sensitive numbers while sharing your screen.",
                enabled: nil)
            if expanded.contains("presenter") { PresenterRows() }

            header(
                "colorPicker", title: "Color Picker", icon: "eyedropper",
                subtitle: "System loupe on a hotkey, sampled color to your clipboard.",
                enabled: $colorPickerEnabled)
            if expanded.contains("colorPicker") { ColorPickerRows() }
        }
        .formStyle(.grouped)
        .navigationTitle("Extensions")
        .animation(.easeOut(duration: 0.15), value: expanded)
        .onAppear {
            if let id = SharedDefaults.store.string(forKey: "extensionsExpand") {
                expanded.insert(id)
                SharedDefaults.store.removeObject(forKey: "extensionsExpand")
            }
        }
    }

    private func header(
        _ id: String, title: String, icon: String, subtitle: String,
        enabled: Binding<Bool>?, expandable: Bool = true, group: String? = nil
    ) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let enabled {
                    Toggle("", isOn: enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .pointerCursor()
                }
                if expandable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.contains(id) ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard expandable else { return }
                if expanded.contains(id) {
                    expanded.remove(id)
                } else {
                    expanded.insert(id)
                }
            }
            .pointerCursor()
        } header: {
            if let group { Text(group) }
        }
    }
}

private struct UsageRows: View {
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var enabled = true
    @AppStorage("limitsInMenuBar", store: SharedDefaults.store) private var limitsInMenuBar = true

    var body: some View {
        Section {
            Toggle("Show Claude usage (5h / 7d)", isOn: $limitsInMenuBar)
                .pointerCursor()
            LabeledContent("Alerts, budget, and readout colors") {
                Button("Open Usage settings") {
                    SharedDefaults.store.set("usage", forKey: "settingsTab")
                    SharedDefaults.store.set(
                        MainDestination.settings.rawValue, forKey: "mainWindowSection")
                }
                .pointerCursor()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct SystemStatsRows: View {
    @AppStorage("menuBarSystemStats", store: SharedDefaults.store) private var enabled = false
    @AppStorage("menuBarStatsColorHex", store: SharedDefaults.store) private var statsColorHex =
        "FFFFFF"

    var body: some View {
        Section {
            ColorPicker(
                "Color",
                selection: Binding(
                    get: { DashPalette.color(statsColorHex) },
                    set: { statsColorHex = $0.hex6 }),
                supportsOpacity: false)
            Text("Sampled every couple of seconds; costs nothing measurable.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct MusicRows: View {
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var enabled = true

    var body: some View {
        Section {
            LabeledContent("Music folder") {
                Button("Open in Finder") {
                    try? FileManager.default.createDirectory(
                        at: Repo.musicDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Repo.musicDir)
                }
                .pointerCursor()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct SystemRows: View {
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var enabled = true
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false
    @State private var cleaningStarted = false

    var body: some View {
        Section {
            Toggle(isOn: $preventSleep) {
                HStack(spacing: 6) {
                    Text("Prevent sleep")
                    InfoDot(
                        "Keeps your Mac awake until you turn this off again, even with the lid closed on power."
                    )
                }
            }
            .pointerCursor()
            HStack {
                Text("Keyboard cleaning")
                InfoDot(
                    "Locks the keyboard so you can wipe it without typing anything. Press the on-screen button or wait for the timer to unlock."
                )
                Spacer()
                if cleaningStarted {
                    Text("Locked - check the overlay")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Clean now") {
                    IPC.post(IPC.Name.requestKeyboardClean)
                    cleaningStarted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        cleaningStarted = false
                    }
                }
                .pointerCursor()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
