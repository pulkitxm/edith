import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct WorkspaceFilterRowButton<Content: View>: View {
    var highlighted: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(8)) {
                content()
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.edith(.row, selected: highlighted))
    }
}
