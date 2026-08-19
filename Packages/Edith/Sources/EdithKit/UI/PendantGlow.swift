import SwiftUI

extension View {
    public func pendantGlow(
        dark: Bool, anchor: UnitPoint = .top, tint: Color? = nil, intensity: Double = 1.0
    ) -> some View {
        background(
            GeometryReader { geo in
                let color = tint ?? DashSkin.accent(dark)
                let base = dark ? 0.22 : 0.14
                RadialGradient(
                    colors: [
                        color.opacity(base * intensity),
                        DashSkin.gold.opacity(base * 0.5 * intensity),
                        .clear,
                    ],
                    center: anchor,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.65
                )
                .allowsHitTesting(false)
            }
        )
    }
}
