import EdithKit
import SwiftUI

struct LiquidTabPicker<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: UIScale.pt(2)) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                        selection = item
                    }
                } label: {
                    Text(label(item))
                        .font(.system(size: UIScale.pt(12.5), weight: .medium))
                        .foregroundStyle(selected ? DashSkin.paper(dark) : DashSkin.inkSoft(dark))
                        .padding(.horizontal, UIScale.pt(12))
                        .padding(.vertical, UIScale.pt(6))
                }
                .buttonStyle(.plain)
                .background(
                    Capsule()
                        .foregroundStyle(selected ? DashSkin.ink(dark) : .clear)
                )
                .pointerCursor()
            }
        }
        .padding(UIScale.pt(3))
    }
}
