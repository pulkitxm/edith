import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

struct AppGlyph: View {
    var icon: EdithIcon
    var logoName: String?
    var size: CGFloat

    var body: some View {
        Group {
            if let logoName, let image = ProviderLogo.image(named: logoName) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                EdithIconView(icon).font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
