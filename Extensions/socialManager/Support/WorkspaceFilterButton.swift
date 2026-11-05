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
                .accessibilityHidden(true)
        }
        .buttonStyle(.pageChip(active: active, iconOnly: true))
        .fixedSize()
        .overlay(alignment: .topTrailing) {
            if active {
                Text(count > 9 ? "9+" : "\(count)")
                    .font(.edithText(.caption2).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.onAccent(dark))
                    .padding(.horizontal, UIScale.pt(3))
                    .padding(.vertical, UIScale.pt(1))
                    .background(DashSkin.accent(dark), in: Capsule())
                    .offset(x: UIScale.pt(4), y: UIScale.pt(-4))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
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
