import EdithKit
import SwiftUI

struct WorkspaceTabChip<Content: View>: View {
    let id: String
    let selected: Bool
    var fill: Color?
    var stroke: Color?
    let select: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content()
            .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(6))
            .widgetBar(
                cornerRadius: 8,
                fill: fill
                    ?? (selected ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.55)),
                stroke: stroke ?? (selected ? DashSkin.lineStrong(dark) : DashSkin.line(dark)),
                strokeWidth: selected ? 1.4 : 1
            )
            .contentShape(Rectangle())
            .herdrDropFrame(HerdrDropGeometry.chipPrefix + id)
            .onTapGesture(perform: select)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var dark: Bool { scheme == .dark }
}

struct WorkspaceLayoutButton<Content: View>: View {
    let split: Bool
    @Binding var presented: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: split ? "square.grid.2x2" : "plus.rectangle.on.rectangle")
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                .padding(UIScale.pt(4))
                .widgetBar(
                    cornerRadius: 8,
                    fill: presented ? DashSkin.accent(dark).opacity(0.18) : DashSkin.paper2(dark),
                    stroke: DashSkin.line(dark))
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel(split ? "Layout" : "Side by side")
        .help(split ? "Arrange the panes in this tab" : "Show panes side by side")
        .popover(isPresented: $presented, arrowEdge: .bottom, content: content)
    }

    private var dark: Bool { scheme == .dark }
}
