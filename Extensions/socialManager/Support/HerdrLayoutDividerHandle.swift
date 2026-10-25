import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrLayoutDividerHandle: View {
    let axis: SplitAxis
    let dark: Bool
    let onDrag: (CGFloat) -> Void
    let onEqualize: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        let active = hovering || dragging
        ZStack {
            Capsule()
                .fill(active ? DashSkin.accent(dark) : Color.clear)
                .frame(
                    width: axis == .horizontal ? UIScale.pt(3) : nil,
                    height: axis == .horizontal ? nil : UIScale.pt(3)
                )
                .padding(axis == .horizontal ? .vertical : .horizontal, UIScale.pt(10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            } else if !dragging {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    let travelled =
                        axis == .horizontal ? value.translation.width : value.translation.height
                    let delta = travelled - lastTranslation
                    lastTranslation = travelled
                    onDrag(delta)
                }
                .onEnded { _ in
                    dragging = false
                    lastTranslation = 0
                    if !hovering { NSCursor.arrow.set() }
                }
        )
        .onTapGesture(count: 2, perform: onEqualize)
        .accessibilityLabel("Resize the panes")
        .help("Drag to resize, double-click to even out")
    }
}
