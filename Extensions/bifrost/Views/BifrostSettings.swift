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
            PageHeader("Bifrost")
        } content: {
            Form { BifrostRows() }.formStyle(.grouped).edithForm()
        }.pageTask { await context?.load() }
    }
}
