import EdithExtensionUI
import SwiftUI

struct SocialCardButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .edithHoverHighlight(
                tone: .neutral, cornerRadius: UIScale.pt(cornerRadius),
                pressed: configuration.isPressed)
    }
}
