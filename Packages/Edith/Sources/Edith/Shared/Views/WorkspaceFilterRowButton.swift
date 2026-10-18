import EdithKit
import SwiftUI

struct WorkspaceFilterRowButton<Content: View>: View {
    var highlighted: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(8)) {
                content()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                highlighted ? DashSkin.accent(scheme == .dark).opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(8), style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
    }
}
