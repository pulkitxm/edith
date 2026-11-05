import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct WorkspaceTabChip<Content: View>: View {
    let id: String
    let selected: Bool
    let select: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content()
            .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            .pageChipChrome(active: selected)
            .herdrDropFrame(HerdrDropGeometry.chipPrefix + id)
            .onTapGesture(perform: select)
    }

    private var dark: Bool { scheme == .dark }
}

struct WorkspaceLayoutButton<Content: View>: View {
    let split: Bool
    @Binding var presented: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            EdithIconView(split ? .grid : .plus)
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .accessibilityHidden(true)
        }
        .buttonStyle(.pageChip(active: presented, iconOnly: true))
        .fixedSize()
        .accessibilityLabel(split ? "Layout" : "Side by side")
        .help(split ? "Arrange the panes in this tab" : "Show panes side by side")
        .popover(isPresented: $presented, arrowEdge: .bottom, content: content)
    }
}
