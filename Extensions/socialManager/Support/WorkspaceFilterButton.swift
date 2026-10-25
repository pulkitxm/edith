import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct WorkspaceFilterButton<Content: View>: View {
    @Binding var presented: Bool
    var count: Int
    var label: String
    var summary: String
    var help: String
    var onPress: () -> Void
    var onDismissed: () -> Void = {}
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var active: Bool { count > 0 }

    var body: some View {
        Button(action: onPress) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(active ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                .frame(minWidth: UIScale.pt(22), minHeight: UIScale.pt(22))
                .padding(.horizontal, UIScale.pt(4))
                .padding(.vertical, UIScale.pt(4))
                .widgetBar(
                    cornerRadius: 8,
                    fill: active ? DashSkin.accent(dark).opacity(0.18) : DashSkin.paper2(dark),
                    stroke: active ? DashSkin.accent(dark).opacity(0.65) : DashSkin.line(dark),
                    strokeWidth: active ? 1.4 : 1
                )
                .overlay(alignment: .topTrailing) {
                    if active {
                        Text(count > 9 ? "9+" : "\(count)")
                            .font(DashSkin.mono(8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, UIScale.pt(3))
                            .padding(.vertical, UIScale.pt(1))
                            .background(DashSkin.accent(dark), in: Capsule())
                            .offset(x: UIScale.pt(4), y: UIScale.pt(-4))
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel(label)
        .accessibilityValue(summary)
        .help(help)
        .popover(isPresented: popoverPresented, arrowEdge: .top, content: content)
    }

    private var popoverPresented: Binding<Bool> {
        Binding(
            get: { presented },
            set: { isPresented in
                if isPresented {
                    presented = true
                } else if presented {
                    presented = false
                    onDismissed()
                }
            })
    }
}
