import EdithKit
import SwiftUI

struct SelectableChipRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let selected: Bool
    let dark: Bool
    let onSelect: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: icon)
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(selected ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    Text(title)
                        .font(.system(size: UIScale.pt(12.5), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
                trailing()
            }
            .padding(.horizontal, UIScale.pt(11))
            .padding(.vertical, UIScale.pt(8))
            .widgetBar(
                cornerRadius: 11,
                fill: selected ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.55),
                stroke: selected ? DashSkin.accent(dark).opacity(0.55) : DashSkin.line(dark),
                strokeWidth: selected ? 1.4 : 1
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
