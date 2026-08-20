import EdithKit
import SwiftUI

struct AppGlyph: View {
    var systemName: String
    var logoName: String?
    var size: CGFloat
    var weight: Font.Weight = .medium

    init(
        systemName: String, logoName: String? = nil, size: CGFloat,
        weight: Font.Weight = .medium
    ) {
        self.systemName = systemName
        self.logoName = logoName
        self.size = size
        self.weight = weight
    }

    init(_ destination: MainDestination, size: CGFloat, weight: Font.Weight = .medium) {
        self.init(
            systemName: destination.icon, logoName: destination.logoName, size: size,
            weight: weight)
    }

    init(_ entry: ExtensionRegistryEntry, size: CGFloat, weight: Font.Weight = .medium) {
        self.init(
            systemName: entry.symbolName, logoName: entry.logoName, size: size, weight: weight)
    }

    var body: some View {
        Group {
            if let logoName, let image = ProviderLogo.image(named: logoName) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: systemName)
                    .font(.system(size: size, weight: weight))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
