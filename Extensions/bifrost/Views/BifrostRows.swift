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
    @State private var index: BifrostIndex?

    var body: some View {
        Group {
            Section {
                Button("Open Bifrost") {
                    BifrostUIContext.perform("open")
                }
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "bifrostHotKey", defaultLabel: "⌥␣")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Launcher hotkey")
                        InfoDot("Opens the bar over whatever you are doing.")
                    }
                }
                Picker(selection: $popupAt.bifrostSetting(AppStorageKeys.Bifrost.popupAt)) {
                    ForEach(PopupPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Bar opens at")
                        InfoDot("Where the launcher appears when you summon it.")
                    }
                }
                Stepper(
                    value: $resultLimit.bifrostSetting(AppStorageKeys.Bifrost.resultLimit),
                    in: BifrostQuery.minimumResultLimit...BifrostQuery.maximumResultLimit
                ) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Results shown: \(resultLimit)")
                        InfoDot("How many rows the bar lists under the field.")
                    }
                }
            } header: {
                Text("Launcher")
            } footer: {
                Text(BifrostSummary.availability(index: index))
                    .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!bifrostEnabled)
            .opacity(bifrostEnabled ? 1 : 0.5)

            Section {
                ForEach(BifrostSource.allCases, id: \.self) { source in
                    BifrostSourceToggle(source: source)
                }
                Toggle(
                    "Paste snippets into the app you were typing in",
                    isOn: $pasteSnippets.bifrostSetting(AppStorageKeys.Bifrost.pasteSnippets))
                Text("Needs Accessibility. Without it a snippet is only copied.")
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(.secondary)
            } header: {
                Text("What else it searches")
            } footer: {
                Text(
                    "Applications, the calculator, unit and currency conversion, clipboard history and file search are always on. These are the extra sources."
                )
                .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!bifrostEnabled)
            .opacity(bifrostEnabled ? 1 : 0.5)

            Section {
                BifrostQuicklinkEditor()
            } header: {
                Text("Quicklinks")
            }
            .disabled(!bifrostEnabled)
            .opacity(bifrostEnabled ? 1 : 0.5)

            Section {
                BifrostSnippetEditor()
            } header: {
                Text("Snippets")
            }
            .disabled(!bifrostEnabled)
            .opacity(bifrostEnabled ? 1 : 0.5)

            Section {
                BifrostShellCommandEditor()
            } header: {
                Text("Shell commands")
            }
            .disabled(!bifrostEnabled)
            .opacity(bifrostEnabled ? 1 : 0.5)

            if bifrostEnabled {
                Section {
                    Button("Rebuild index") {
                        BifrostUIContext.perform("reindex")
                    }
                    Button("Clear frequently opened", role: .destructive) {
                        BifrostUIContext.perform("clear")
                        index = BifrostUIContext.loadIndex()
                    }
                } header: {
                    Text("Index")
                } footer: {
                    Text(
                        "Bifrost indexes the application folders on this Mac. Rebuild it after installing something it has not noticed."
                    )
                    .font(.system(size: UIScale.pt(10)))
                }
            }
        }
        .onAppear { index = BifrostUIContext.loadIndex() }
        .onReceive(NotificationCenter.default.publisher(for: BifrostIPC.Name.bifrostIndexChanged)) {
            _ in
            index = BifrostUIContext.loadIndex()
        }
    }
}

private struct BifrostSourceToggle: View {
    let source: BifrostSource

    @State private var isOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Toggle(source.title, isOn: $isOn)
                .onChange(of: isOn) { _, value in
                    BifrostUIContext.write(source.defaultsKey, value: value)
                }
            Text(source.summary)
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(.secondary)
        }
        .onAppear { isOn = source.isEnabled() }
    }
}
