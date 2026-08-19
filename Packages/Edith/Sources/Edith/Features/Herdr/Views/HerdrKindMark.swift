import EdithKit
import SwiftUI

struct HerdrKindMark: View {
    let kind: String
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let name = HerdrKind.logoName(for: kind), let image = ProviderLogo.image(named: name)
            {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Text(HerdrKind.monogram(for: kind))
                    .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
