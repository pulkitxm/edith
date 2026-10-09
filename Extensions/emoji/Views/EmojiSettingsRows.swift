import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct EmojiSettingsRows: View {
    @AppStorage(AppStorageKeys.Emoji.skinTone, store: SharedDefaults.store) private var tone = 0
    @AppStorage(AppStorageKeys.Emoji.popupAt, store: SharedDefaults.store) private var popupAt =
        "cursor"
    @AppStorage(AppStorageKeys.Emoji.frequentCount, store: SharedDefaults.store) private
        var frequentCount = 10

    var body: some View {
        Section("Picker") {
            Button("Open Picker") { EmojiPanel.shared.show() }
            LabeledContent("Shortcut") {
                HotKeyRecorderControl(keyPrefix: "emojiHotKey", defaultLabel: "⌃⇧E")
            }
            Picker("Skin tone", selection: $tone.notifyingSettingsChange()) {
                ForEach(EmojiSkinTone.allCases) { tone in Text(tone.title).tag(tone.rawValue) }
            }
            Picker("Open at", selection: $popupAt.notifyingSettingsChange()) {
                ForEach(PopupPosition.allCases) { position in
                    Text(position.title).tag(position.rawValue)
                }
            }
            Text(EmojiCatalogSummary.availability).settingsCaption()
        }
        Section("Frequently Used") {
            Stepper(
                "Show \(frequentCount) emoji", value: $frequentCount.notifyingSettingsChange(),
                in: 0...24)
            Button("Clear Frequently Used", role: .destructive) {
                _ = try? EmojiOperationExecution.perform(.clear)
            }
        }
    }
}
