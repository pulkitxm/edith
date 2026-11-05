import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct BifrostRows: View {
    @AppStorage(AppStorageKeys.Bifrost.enabled, store: SharedDefaults.store) private
        var bifrostEnabled =
        true
    @AppStorage(AppStorageKeys.Bifrost.popupAt, store: SharedDefaults.store) private var popupAt =
        "center"
    @AppStorage(AppStorageKeys.Bifrost.resultLimit, store: SharedDefaults.store) private
        var resultLimit = BifrostQuery.defaultLimit
    @AppStorage(AppStorageKeys.Bifrost.pasteSnippets, store: SharedDefaults.store) private
        var pasteSnippets = true
    var error: String? = nil
    @State private var index: BifrostIndex?

    var body: some View {
        Group {
            if !bifrostEnabled {
                Section {
                    SettingsNoticeRow(
                        "Launcher is off",
                        message:
                            "Turn it on to open apps and search from one bar, and to change these settings.",
                        symbol: "power.circle.fill")
                }
            } else if let error {
                Section {
                    SettingsErrorRow(
                        "A change was not saved", message: error,
                        retry: { Task { await BifrostUIContext.current?.load() } })
                }
            }
            Group {
                Section {
                    LabeledContent {
                        Button("Open Launcher") { BifrostUIContext.perform("open") }
                            .buttonStyle(.edith(.primary))
                    } label: {
                        Text("Search anything")
                        Text("Type an app name, a sum like 12 * 8, or part of a file name.")
                    }
                    SettingsShortcutRow(
                        keyPrefix: "bifrostHotKey", defaultLabel: "\u{2325}\u{2423}",
                        purpose: "Opens the launcher over whatever you are doing.")
                }
                Section {
                    Picker(selection: $popupAt.bifrostSetting(AppStorageKeys.Bifrost.popupAt)) {
                        ForEach(PopupPosition.allCases) { position in
                            Text(position.title).tag(position.rawValue)
                        }
                    } label: {
                        Text("Opens at")
                        Text("Where the launcher appears when you press the shortcut.")
                    }
                    SettingsRow(
                        "Results to show",
                        subtitle: "How many matches are listed under the search field."
                    ) {
                        HStack(spacing: UIScale.pt(8)) {
                            Text("\(resultLimit)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: UIScale.pt(28), alignment: .trailing)
                            Stepper(
                                "Results to show",
                                value: $resultLimit.bifrostSetting(
                                    AppStorageKeys.Bifrost.resultLimit),
                                in: BifrostQuery
                                    .minimumResultLimit...BifrostQuery.maximumResultLimit
                            )
                            .labelsHidden()
                        }
                    }
                } header: {
                    Text("Launcher")
                } footer: {
                    BifrostFootnote(BifrostSummary.availability(index: index))
                }
                Section {
                    ForEach(BifrostSource.allCases, id: \.self) { source in
                        BifrostSourceToggle(source: source)
                    }
                } header: {
                    Text("Also search")
                } footer: {
                    BifrostFootnote(
                        "Apps, math, unit and currency conversion, clipboard history and files are always searched."
                    )
                }
                Section {
                    BifrostQuicklinkEditor()
                } header: {
                    Text("Quicklinks")
                }
                Section {
                    Toggle(
                        isOn: $pasteSnippets.bifrostSetting(AppStorageKeys.Bifrost.pasteSnippets)
                    ) {
                        Text("Paste snippets for me")
                        Text(
                            "Types the snippet into the app you were using. Needs Accessibility; without it the snippet is only copied."
                        )
                    }
                    BifrostSnippetEditor()
                } header: {
                    Text("Snippets")
                }
                Section {
                    BifrostShellCommandEditor()
                } header: {
                    Text("Shell commands")
                }
                Section("Index") {
                    LabeledContent {
                        Button("Rebuild") { BifrostUIContext.perform("reindex") }
                            .buttonStyle(.edith(.secondary))
                    } label: {
                        Text("Find new apps")
                        Text(
                            "Scans your application folders again. Use it if a new app is missing.")
                    }
                    LabeledContent {
                        Button("Reset", role: .destructive) {
                            BifrostUIContext.perform("clear")
                            index = BifrostUIContext.loadIndex()
                        }
                        .buttonStyle(.edith(.secondary))
                    } label: {
                        Text("Reset app ranking")
                        Text("Forgets which apps you open most. No apps or files are removed.")
                    }
                }
            }
            .disabled(!bifrostEnabled)
            .opacity(bifrostEnabled ? 1 : 0.5)
        }
        .onAppear { index = BifrostUIContext.loadIndex() }
        .pageRefresh(interval: { .seconds(4) }) {
            await BifrostUIContext.current?.load()
            index = BifrostUIContext.loadIndex()
        }
        .onReceive(NotificationCenter.default.publisher(for: BifrostIPC.Name.bifrostIndexChanged)) {
            _ in
            index = BifrostUIContext.loadIndex()
        }
    }
}

struct BifrostFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.edithText(.subheadline))
            .foregroundStyle(.secondary)
    }
}

private struct BifrostSourceToggle: View {
    let source: BifrostSource

    @State private var isOn = false

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(source.title)
            Text(source.summary)
        }
        .onChange(of: isOn) { _, value in
            BifrostUIContext.write(source.defaultsKey, value: value)
        }
        .onAppear { isOn = source.isEnabled() }
    }
}
