import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct EmojiSettingsRows: View {
    let presentation: ControlPresentation
    @AppStorage(AppStorageKeys.Emoji.skinTone, store: SharedDefaults.store) private var skinTone = 0
    @AppStorage(AppStorageKeys.Emoji.popupAt, store: SharedDefaults.store) private var popupAt =
        "cursor"
    @AppStorage(AppStorageKeys.Emoji.frequentCount, store: SharedDefaults.store) private
        var frequentCount = 10
    @State private var frequent: [String] = []

    private var enabled: Bool { presentation.active }

    var body: some View {
        Group {
            if !enabled {
                Section {
                    SettingsNoticeRow(
                        "Emoji Picker is off",
                        message: "Turn it on to type emoji from any app and change these settings.",
                        icon: .power)
                }
            } else if presentation.ready, let error = presentation.error {
                Section {
                    SettingsErrorRow(
                        "Emoji Picker is not responding", message: error,
                        retry: presentation.retry)
                }
            }
            Group {
                Section {
                    LabeledContent {
                        Button("Open Picker") { presentation.perform("pick") }
                            .buttonStyle(.edith(.primary))
                    } label: {
                        Text("Type an emoji")
                        Text("Search by name, then press Return to type it where your cursor is.")
                    }
                    SettingsShortcutRow(
                        keyPrefix: "emojiHotKey", defaultLabel: "\u{2303}\u{21E7}E",
                        purpose: "Opens the picker over whatever you are typing in.")
                }
                Section {
                    Picker(selection: $popupAt.notifyingSettingsChange()) {
                        ForEach(PopupPosition.allCases) { position in
                            Text(position.title).tag(position.rawValue)
                        }
                    } label: {
                        Text("Opens at")
                        Text("Where the picker appears when you press the shortcut.")
                    }
                    Picker(selection: $skinTone.notifyingSettingsChange()) {
                        ForEach(EmojiSkinTone.allCases) { option in
                            Text("\(option.sample)  \(option.title)").tag(option.rawValue)
                        }
                    } label: {
                        Text("Skin tone")
                        Text("Used for every emoji that has skin tones.")
                    }
                    SettingsRow(
                        "Favorites to show",
                        subtitle:
                            "Your most used emoji, pinned to the top of the picker. Set 0 to hide them."
                    ) {
                        HStack(spacing: UIScale.pt(8)) {
                            Text("\(frequentCount)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: UIScale.pt(28), alignment: .trailing)
                            Stepper(
                                "Favorites to show",
                                value: $frequentCount.notifyingSettingsChange(),
                                in: 0...EmojiCatalogSummary.maxFrequentCount
                            )
                            .labelsHidden()
                        }
                    }
                } header: {
                    Text("Picker")
                } footer: {
                    Text(EmojiCatalogSummary.availability)
                        .font(.edithText(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            if enabled, frequentCount > 0 {
                Section("Your favorites") {
                    if frequent.isEmpty {
                        VStack(spacing: UIScale.pt(2)) {
                            Text("No favorites yet")
                            Text("Emoji you type with the picker show up here, most used first.")
                                .settingsCaption()
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    } else {
                        EmojiFrequentGrid(characters: frequent)
                        LabeledContent {
                            Button("Forget All", role: .destructive) {
                                presentation.perform("clear")
                            }
                            .buttonStyle(.edith(.secondary))
                        } label: {
                            Text("Start over")
                            Text("Clears the list. The emoji themselves are not affected.")
                        }
                    }
                }
            }
        }
        .onAppear { refreshFrequent() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UserDefaults.didChangeNotification, object: SharedDefaults.store)
        ) { _ in refreshFrequent() }
        .onChange(of: frequentCount) { _, _ in refreshFrequent() }
        .onChange(of: skinTone) { _, _ in refreshFrequent() }
    }

    private func refreshFrequent() {
        let next = EmojiCatalogSummary.frequent(store: SharedDefaults.store)
        if next != frequent { frequent = next }
    }
}

private struct EmojiFrequentGrid: View {
    private static let columnsPerRow = 12

    let characters: [String]

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: UIScale.pt(8)),
            count: min(characters.count, Self.columnsPerRow))
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: UIScale.pt(8)) {
            ForEach(characters, id: \.self) { character in
                Text(character)
                    .font(.system(size: UIScale.pt(22)))
                    .frame(width: UIScale.pt(32), height: UIScale.pt(32))
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(character, forType: .string)
                        }
                    }
            }
        }
    }
}
