import EdithExtensionUI
import SwiftUI

struct CodeStatsFilterChip: View {
    let title: String
    let color: Color
    var active = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: UIScale.pt(5)) {
            Circle().fill(color).frame(width: UIScale.pt(7), height: UIScale.pt(7))
            Text(title)
                .font(.system(size: UIScale.pt(11), weight: active ? .semibold : .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
        }
        .padding(.horizontal, UIScale.pt(9))
        .padding(.vertical, UIScale.pt(4))
        .widgetBar(
            cornerRadius: 8,
            fill: active
                ? AnyShapeStyle(color.opacity(0.18)) : AnyShapeStyle(DashSkin.paper2(dark)),
            stroke: active ? color.opacity(0.6) : DashSkin.lineStrong(dark))
    }
}
