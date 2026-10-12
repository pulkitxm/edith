import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

extension Binding {
    @MainActor func bifrostSetting(_ key: String) -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { value in
                wrappedValue = value
                BifrostUIContext.write(key, value: value)
            })
    }
}

struct BifrostSettings: View {
    var context: BifrostUIContext? = nil
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
            if context == nil || context?.loaded == true {
                Form { BifrostRows() }.formStyle(.grouped)
            } else {
                PageLoading(state: .loading, layout: .cards) { EmptyView() }
            }
        }.pageTask { await context?.load() }
    }
}
