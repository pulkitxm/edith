import AppKit
import EdithKit
import SwiftUI

struct SidebarMaterial: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                DashSkin.paper(scheme == .dark)
            } else {
                SidebarVisualEffect()
            }
        }
        .overlay(alignment: .trailing) {
            DashSkin.line(scheme == .dark).frame(width: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct SidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
