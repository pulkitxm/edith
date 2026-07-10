import AppKit
import EdithKit
import SwiftUI

struct ExtensionsPane: View {
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = true
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        true
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
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
                "music", title: "Music", icon: "music.note",
                subtitle: "Plays your local music folder, with media keys.",
                enabled: $musicEnabled)
            if expanded.contains("music") { MusicRows() }

            header(
                "calendar", title: "Calendar", icon: "calendar",
                subtitle: "Shows your schedule in the panel and the app.",
                enabled: $calendarEnabled, expandable: false)

            header(
                "system", title: "System", icon: "switch.2",
                subtitle: "Prevent-sleep toggle and the keyboard-cleaning lock.",
                enabled: $systemEnabled)
            if expanded.contains("system") { SystemRows() }

            header(
                "notchShelf", title: "Notch Shelf", icon: "tray.and.arrow.down",
                subtitle: "Park files under the notch mid-drag.",
                enabled: $notchShelfEnabled)
            if expanded.contains("notchShelf") { NotchShelfRows() }

            header(
                "clipboard", title: "Clipboard", icon: "doc.on.clipboard",
                subtitle: "Clipboard history with instant paste.",
                enabled: $clipboardEnabled)
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

            header(
                "micMute", title: "Mic Mute", icon: "mic.slash.fill",
                subtitle: "Mute every microphone system-wide with ⌘⇧M or the menu bar icon.",
                enabled: $micMuteEnabled)
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
        enabled: Binding<Bool>?, expandable: Bool = true
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
        }
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

    var body: some View {
        Section {
            HStack {
                Toggle("Prevent sleep", isOn: $preventSleep)
                    .pointerCursor()
                InfoDot(
                    "Keeps your Mac awake until you turn this off again, even with the lid closed on power."
                )
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

struct PanelTabsSection: View {
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = true
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = true
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        true

    var body: some View {
        Section {
            Toggle("Agent Usage", isOn: $usageEnabled).pointerCursor()
            Toggle("Music", isOn: $musicEnabled).pointerCursor()
            Toggle("System", isOn: $systemEnabled).pointerCursor()
            Toggle("Calendar", isOn: $calendarEnabled).pointerCursor()
        } header: {
            Text("Features")
        } footer: {
            Text("Turn built-in sections on or off across the app and notch.")
                .font(.caption)
        }
    }
}
