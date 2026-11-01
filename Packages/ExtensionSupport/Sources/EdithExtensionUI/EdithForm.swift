import EdithExtensionCore
import SwiftUI

private struct EdithFormStyle: ViewModifier {
    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.installed.defaults())
    private var themeName = "accent"

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .font(.edithText(.body))
            .tint(themeColor(themeName))
            .scrollContentBackground(.hidden)
    }
}

extension View {
    public func edithForm() -> some View {
        modifier(EdithFormStyle())
    }
}
