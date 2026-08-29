import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct EmojiRows: View {
    @AppStorage(AppStorageKeys.Emoji.enabled, store: SharedDefaults.store) private
        var emojiEnabled =
        false
    @AppStorage(AppStorageKeys.Emoji.frequentCount, store: SharedDefaults.store) private
        var frequentCount = 10
    @AppStorage(AppStorageKeys.Emoji.popupAt, store: SharedDefaults.store) private var popupAt =
        "cursor"
    @AppStorage(AppStorageKeys.Emoji.skinTone, store: SharedDefaults.store) private var skinTone = 0
    @State private var frequent: [String] = []

    private var tone: EmojiSkinTone { EmojiSkinTone(rawValue: skinTone) ?? .standard }

    var body: some View {
        Group {
            Section {
                Button("Open picker") {
                    _ = EmojiOperationExecution.request(.pick)
                }
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "emojiHotKey", defaultLabel: "⌃⇧E")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Picker hotkey")
                        InfoDot("Opens the picker over whatever you are typing in.")
                    }
                }
                Picker(selection: $popupAt.configured(AppStorageKeys.Emoji.popupAt)) {
                    ForEach(PopupPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Popup at")
                        InfoDot("Where the picker appears when you summon it.")
                    }
                }
                Picker(selection: $skinTone.configured(AppStorageKeys.Emoji.skinTone)) {
                    ForEach(EmojiSkinTone.allCases) { option in
                        Text("\(option.sample)  \(option.title)").tag(option.rawValue)
                    }
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Default skin tone")
                        InfoDot("Applied to every emoji that supports one.")
                    }
                }
                Stepper(
                    value: $frequentCount.configured(AppStorageKeys.Emoji.frequentCount),
                    in: 0...EmojiCatalogSummary.maxFrequentCount
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Frequently used: \(frequentCount)")
                        InfoDot("How many of your most-used emoji pin to the top of the picker.")
                    }
                }
            } header: {
                Text("Picker")
            } footer: {
                Text(EmojiCatalogSummary.availability)
                    .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!emojiEnabled)
            .opacity(emojiEnabled ? 1 : 0.5)

            if emojiEnabled, !frequent.isEmpty {
                Section {
                    EmojiFrequentGrid(characters: frequent)
                    Button("Clear frequently used", role: .destructive) {
                        _ = try? EmojiOperationExecution.perform(.clear)
                        frequent = EmojiCatalogSummary.frequent()
                    }
                } header: {
                    Text("Frequently Used")
                }
            }
        }
        .onAppear { frequent = EmojiCatalogSummary.frequent() }
        .onChange(of: frequentCount) { _, _ in frequent = EmojiCatalogSummary.frequent() }
        .onChange(of: tone) { _, _ in frequent = EmojiCatalogSummary.frequent() }
    }
}

private struct EmojiFrequentGrid: View {
    let characters: [String]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: UIScale.pt(28)), spacing: UIScale.pt(6))],
            spacing: UIScale.pt(6)
        ) {
            ForEach(characters, id: \.self) { character in
                Text(character)
                    .font(.system(size: UIScale.pt(20)))
                    .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(character, forType: .string)
                        }
                    }
            }
        }
        .padding(.vertical, UIScale.pt(4))
    }
}
