import EdithExtensionUI
import SwiftUI
struct ZoomableRoot<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.edithText(.body))
            .controlSize(UIScale.controlSize)
            .disclosureGroupStyle(EdithDisclosureGroupStyle())
            .themedControls()
            .tracksWindowVisibility()
    }
}
