import AppKit
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct BifrostRows: View {
    @AppStorage(AppStorageKeys.Bifrost.enabled, store: SharedDefaults.store) private
        var bifrostEnabled =
        false
    @AppStorage(AppStorageKeys.Bifrost.popupAt, store: SharedDefaults.store) private var popupAt =
        "center"
    @AppStorage(AppStorageKeys.Bifrost.resultLimit, store: SharedDefaults.store) private
        var resultLimit = BifrostQuery.defaultLimit
    @State private var index: BifrostIndex?

    var body: some View {
        Group {
            Section {
                Button("Open Bifrost") {
                    _ = BifrostOperationExecution.request(.open)
                }
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "bifrostHotKey", defaultLabel: "⌥␣")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Launcher hotkey")
                        InfoDot("Opens the bar over whatever you are doing.")
                    }
                }
                Picker(selection: $popupAt.configured(AppStorageKeys.Bifrost.popupAt)) {
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
                    value: $resultLimit.configured(AppStorageKeys.Bifrost.resultLimit),
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

            if bifrostEnabled {
                Section {
                    Button("Rebuild index") {
                        _ = BifrostOperationExecution.request(.reindex)
                    }
                    Button("Clear frequently opened", role: .destructive) {
                        _ = BifrostOperationExecution.clear()
                        index = BifrostIndexStore.shared.load()
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
        .onAppear { index = BifrostIndexStore.shared.load() }
        .onReceive(NotificationCenter.default.publisher(for: IPC.Name.bifrostIndexChanged)) { _ in
            index = BifrostIndexStore.shared.load()
        }
    }
}
