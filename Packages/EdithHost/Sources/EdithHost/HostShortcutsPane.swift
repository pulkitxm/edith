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
                conflict: { code, modifiers in
                    HostShortcutConflicts.owner(
                        code: code, modifiers: modifiers, excluding: keyPrefix,
                        among: shortcutOwners
                    ).map(HostShortcutConflicts.message)
                },
                commit: {
                    if keyPrefix == "hotKey" { panelShortcutChanged() }
                    Task {
                        await marketplace.sessions.synchronizeAppearance(
                            identity: marketplace.identity)
                    }
                })
        }
    }

    private var shortcutOwners: [HostShortcutOwner] {
        let panel = HostShortcutConflicts.panel
        return [
            HostShortcutConflicts.owner(
                title: panel.title, prefix: panel.prefix, defaultCode: panel.code,
                defaultModifiers: panel.modifiers, defaults: shortcutDefaults(panel.prefix))
        ]
            + extensionShortcuts.map {
                HostShortcutConflicts.owner(
                    title: $0.title, prefix: $0.prefix, defaultCode: $0.defaultCode,
                    defaultModifiers: $0.defaultModifiers, defaults: shortcutDefaults($0.prefix))
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
        case .hinge:
            shortcutRow(
                "Hinge", subtitle: "Turns the desktop fold on or off",
                keyPrefix: "hingeHotKey", defaultLabel: "⌃⌥H")
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
    case bifrost, clipboard, emoji, micMute, focusDim, hinge, presenter, colorPicker,
        keystrokeHighlight, virtualCamera
    var prefix: String {
        switch self {
        case .micMute: "micHotKey"
        default: rawValue + "HotKey"
        }
    }
    var title: String {
        switch self {
        case .bifrost: "Bifrost"
        case .clipboard: "Clipboard history"
        case .emoji: "Emoji picker"
        case .micMute: "Mic mute"
        case .focusDim: "Focus dim"
        case .hinge: "Hinge"
        case .presenter: "Presenter mode"
        case .colorPicker: "Pick a color"
        case .keystrokeHighlight: "Keystroke highlight"
        case .virtualCamera: "Virtual Camera"
        }
    }
    var defaultCode: Int {
        switch self {
        case .bifrost: kVK_Space
        case .clipboard: kVK_ANSI_C
        case .emoji: kVK_ANSI_E
        case .micMute: kVK_ANSI_M
        case .focusDim: kVK_ANSI_F
        case .hinge: kVK_ANSI_H
        case .presenter: kVK_ANSI_P
        case .colorPicker: kVK_ANSI_C
        case .keystrokeHighlight: kVK_ANSI_K
        case .virtualCamera: kVK_ANSI_V
        }
    }
    var defaultModifiers: Int {
        switch self {
        case .bifrost: optionKey
        case .clipboard, .emoji: controlKey | shiftKey
        case .micMute: cmdKey | shiftKey
        case .focusDim: optionKey | cmdKey
        case .hinge: controlKey | optionKey
        case .presenter: shiftKey | optionKey | cmdKey
        case .colorPicker, .keystrokeHighlight, .virtualCamera: controlKey | optionKey | cmdKey
        }
    }
}
