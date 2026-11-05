import EdithExtensionCore
import SwiftUI

private struct EdithFormRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            LabeledContent {
                EmptyView()
            } label: {
                configuration.label
            }
            .labeledContentStyle(.automatic)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct EdithFormStyle: ViewModifier {
    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = "accent"

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .labeledContentStyle(EdithFormRowStyle())
            .font(.edithText(.body))
            .tint(themeColor(themeName))
            .scrollContentBackground(.hidden)
    }
}

extension View {
    public func edithForm() -> some View {
        modifier(EdithFormStyle())
    }

    public func settingsForm() -> some View {
        edithForm().controlSize(UIScale.controlSize)
    }
}
