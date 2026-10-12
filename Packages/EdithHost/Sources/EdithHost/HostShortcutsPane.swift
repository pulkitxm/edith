import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostShortcutsPane: View {
    let marketplace: HostMarketplace
    var panelShortcutChanged: () -> Void = {}
    private var extensionShortcuts: [HostExtensionShortcut] {
        HostExtensionShortcut.allCases.filter {
            marketplace.surfaceAvailability.activeIDs.contains($0.rawValue)
        }
    }
    var body: some View {
        Form {
            Section {
                shortcutRow(
                    "Open panel", subtitle: "Opens the menu bar panel from anywhere",
                    keyPrefix: "hotKey", defaultLabel: "⌥⌘E")
            } header: {
                Text("Global")
            }

            Section {
                if extensionShortcuts.isEmpty {
                    Text("Extensions with shortcuts appear here when enabled.")
                        .settingsCaption()
                } else {
                    ForEach(extensionShortcuts, id: \.self) { shortcut in
                        extensionShortcutRow(shortcut)
                    }
                }
            } header: {
                Text("Extensions")
            }

            Section {
                LabeledContent("Toggle sidebar") {
                    Text("⌘B")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Toggle agent details") {
                    Text("⌥⌘B")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Close panel") {
                    Text("Esc")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Toggle agent terminals") {
                    Text("⌃` or ⌘J")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("New agent terminal") {
                    Text("⌃⇧`")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Back") {
                    Text("⌘[")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Forward") {
                    Text("⌘]")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .kerning(2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Fixed")
            } footer: {
                Text("Click a shortcut to record a new one; Esc cancels recording.")
                    .font(.system(size: UIScale.pt(10)))
            }
        }
        .edithForm()
        .navigationTitle("Shortcuts")
    }

    private func shortcutRow(
        _ title: String, subtitle: String, keyPrefix: String, defaultLabel: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                Text(subtitle)
                    .settingsCaption()
            }
            Spacer()
            HostHotKeyRecorder(
                keyPrefix: keyPrefix, defaultLabel: defaultLabel,
                defaults: shortcutDefaults(keyPrefix),
                commit: {
                    if keyPrefix == "hotKey" { panelShortcutChanged() }
                    Task {
                        await marketplace.sessions.synchronizeAppearance(
                            identity: marketplace.identity)
                    }
                })
        }
    }

    private func shortcutDefaults(_ keyPrefix: String) -> UserDefaults {
        guard
            let id = HostExtensionShortcut.allCases.first(where: { $0.prefix == keyPrefix })?
                .rawValue,
            let defaults = UserDefaults(suiteName: marketplace.identity.extensionDefaultsSuite(id))
        else { return SharedDefaults.store }
        return defaults
    }

    @ViewBuilder
    private func extensionShortcutRow(_ shortcut: HostExtensionShortcut) -> some View {
        switch shortcut {
        case .bifrost:
            shortcutRow(
                "Bifrost", subtitle: "Opens the launcher bar over whatever you are doing",
                keyPrefix: "bifrostHotKey", defaultLabel: "\u{2325}\u{2423}")
        case .clipboard:
            shortcutRow(
                "Clipboard history", subtitle: "Opens the clipboard history popup",
                keyPrefix: "clipboardHotKey", defaultLabel: "⌃⇧C")
        case .emoji:
            shortcutRow(
                "Emoji picker", subtitle: "Opens the emoji picker over whatever you are typing in",
                keyPrefix: "emojiHotKey", defaultLabel: "⌃⇧E")
        case .micMute:
            shortcutRow(
                "Mic mute", subtitle: "Mutes or unmutes every microphone system-wide",
                keyPrefix: "micHotKey", defaultLabel: "⌘⇧M")
        case .focusDim:
            shortcutRow(
                "Focus dim", subtitle: "Toggles background-window dimming",
                keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F")
        case .presenter:
            shortcutRow(
                "Presenter mode", subtitle: "Forces presenter blur on or off",
                keyPrefix: "presenterHotKey", defaultLabel: "⇧⌥⌘P")
        case .colorPicker:
            shortcutRow(
                "Pick a color", subtitle: "Summons the color picker loupe",
                keyPrefix: "colorPickerHotKey", defaultLabel: "⌃⌥⌘C")
        case .keystrokeHighlight:
            shortcutRow(
                "Keystroke highlight", subtitle: "Starts or pauses the on-screen keycaps",
                keyPrefix: "keystrokeHighlightHotKey", defaultLabel: "⌃⌥⌘K")
        case .virtualCamera:
            shortcutRow(
                "Virtual Camera", subtitle: "Pauses Edith Camera behind a card, or goes live again",
                keyPrefix: "virtualCameraHotKey", defaultLabel: "⌃⌥⌘V")
        }
    }
}

enum HostExtensionShortcut: String, CaseIterable {
    case bifrost, clipboard, emoji, micMute, focusDim, presenter, colorPicker, keystrokeHighlight,
        virtualCamera
    var prefix: String {
        switch self {
        case .micMute: "micHotKey"
        default: rawValue + "HotKey"
        }
    }
}
