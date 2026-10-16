import EdithExtensionUI
import SwiftUI
struct QuinjetToolbarButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        configuration.label
            .font(.system(size: UIScale.pt(11), weight: .medium))
            .foregroundStyle(DashSkin.ink(dark))
            .padding(.horizontal, UIScale.pt(10))
            .frame(height: UIScale.pt(30))
            .background(
                hovering ? DashSkin.inkFaint(dark).opacity(0.12) : DashSkin.paper2(dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(7))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(7))
                    .strokeBorder(DashSkin.lineStrong(dark))
            }
            .edithButtonTarget(.toolbar)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { hovering = $0 }
    }
}
