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
        Group {
            if let context, !context.loaded {
                if let error = context.error {
                    PageEmptyState(
                        symbolName: "exclamationmark.triangle",
                        title: "Launcher settings did not load",
                        message: error + " Your shortcuts, snippets and quicklinks are safe.",
                        primary: PageAction("Try Again", symbolName: "arrow.clockwise") {
                            Task { await context.load() }
                        })
                } else {
                    PageSkeleton(layout: .editor)
                        .padding(UIScale.pt(20))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else {
                Form { BifrostRows(error: context?.error) }.deskForm()
            }
        }
        .pageTask { await context?.load() }
    }
}
