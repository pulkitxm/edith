import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

extension Binding {
    func bifrostSetting(_ key: String) -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { value in
                wrappedValue = value
                SharedDefaults.store.set(value, forKey: key)
                BifrostIPC.post(BifrostIPC.Name.settingsChanged)
            })
    }
}

struct BifrostSettings: View {
    var body: some View {
        PageWorkspace {
            PageHeader(
                "Bifrost",
                accessory: {
                    Text("Apps, commands, clipboard history and file search").font(
                        .edithText(.caption)
                    ).foregroundStyle(.secondary)
                })
        } content: {
            Form { BifrostRows() }.formStyle(.grouped)
        }
    }
}
