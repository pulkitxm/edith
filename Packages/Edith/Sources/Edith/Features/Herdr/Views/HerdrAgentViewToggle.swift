import EdithKit
import SwiftUI

struct HerdrAgentViewToggle: View {
    let selection: HerdrAgentView
    var compactStyle = false
    let select: (HerdrAgentView) -> Void

    @Environment(\.colorScheme) private var scheme

    private static let options: [HerdrAgentView] = [.diff, .agent]

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            ForEach(Self.options, id: \.self) { option in
                button(option)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func button(_ option: HerdrAgentView) -> some View {
        let selected = option == selection
        return Button {
            select(option)
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: option.icon)
                    .font(.system(size: UIScale.pt(compactStyle ? 9 : 10), weight: .semibold))
                Text(option.title)
                    .font(
                        .system(
                            size: UIScale.pt(compactStyle ? 10 : 11),
                            weight: selected ? .semibold : .medium)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            .padding(.vertical, UIScale.pt(compactStyle ? 5 : 6))
            .frame(maxWidth: .infinity)
            .widgetBar(
                cornerRadius: 7,
                fill: selected ? DashSkin.paper2(dark) : DashSkin.paper2(dark).opacity(0.5),
                stroke: selected ? DashSkin.accent(dark).opacity(0.55) : DashSkin.line(dark),
                strokeWidth: selected ? 1.4 : 1)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(option == .diff ? "Show the Quinjet diff" : "Show the agent session")
    }
}
