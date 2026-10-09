import EdithExtensionUI
import SwiftUI
struct ZoomableRoot<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: UIScale.pt(13)))
            .controlSize(UIScale.controlSize)
            .disclosureGroupStyle(EdithDisclosureGroupStyle())
            .tracksWindowVisibility()
    }
}
