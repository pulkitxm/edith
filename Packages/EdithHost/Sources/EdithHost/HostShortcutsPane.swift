import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostShortcutsPane: View {
    let marketplace: HostMarketplace
    var panelShortcutChanged: () -> Void = {}
    private var extensionShortcuts: [HostHotKey] {
        marketplace.entries.filter {
            marketplace.surfaceAvailability.activeIDs.contains($0.id)
        }.flatMap(\.hotkeys)
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
                    ForEach(extensionShortcuts) { shortcut in
                        shortcutRow(
                            shortcut.title, subtitle: shortcut.subtitle, keyPrefix: shortcut.prefix,
                            defaultLabel: shortcut.label)
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
                    title: $0.title, prefix: $0.prefix, defaultCode: $0.code,
                    defaultModifiers: $0.modifiers, defaults: shortcutDefaults($0.prefix))
            }
    }

    private func shortcutDefaults(_ keyPrefix: String) -> UserDefaults {
        guard
            let id = marketplace.entries.first(where: {
                $0.hotkeys.contains { $0.prefix == keyPrefix }
            })?.id,
            let defaults = UserDefaults(suiteName: marketplace.identity.extensionDefaultsSuite(id))
        else { return SharedDefaults.store }
        return defaults
    }

}
