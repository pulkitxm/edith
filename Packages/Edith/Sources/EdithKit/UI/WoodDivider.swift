import SwiftUI

public struct WoodRule: View {
    let dark: Bool

    public init(dark: Bool) {
        self.dark = dark
    }

    public var body: some View {
        LinearGradient(
            colors: [
                DashSkin.line(dark).opacity(0),
                DashSkin.gold.opacity(dark ? 0.55 : 0.45),
                DashSkin.line(dark).opacity(0),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: UIScale.pt(1))
    }
}

public struct SectionHeading: View {
    let title: String
    let dark: Bool

    public init(_ title: String, dark: Bool) {
        self.title = title
        self.dark = dark
    }

    public var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Text(title)
                .font(DashSkin.serifHeading(dark))
                .foregroundStyle(DashSkin.ink(dark))
            WoodRule(dark: dark)
        }
    }
}

extension ShapeStyle where Self == LinearGradient {
    public static func brassBorder(dark: Bool) -> LinearGradient {
        LinearGradient(
            colors: [
                DashSkin.gold.opacity(dark ? 0.85 : 0.7),
                DashSkin.accentDeep(dark).opacity(0.6),
                DashSkin.gold.opacity(dark ? 0.85 : 0.7),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}
