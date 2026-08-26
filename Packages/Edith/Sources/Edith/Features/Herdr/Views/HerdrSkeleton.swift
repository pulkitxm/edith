import EdithKit
import SwiftUI

struct HerdrSkeleton: View {
    let dark: Bool
    var rows: Int = 3
    var card = true

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(card ? 10 : 6)) {
                ForEach(0..<rows, id: \.self) { index in
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        bar(width: card ? 0.42 : 0.3, height: 9)
                        bar(width: index.isMultiple(of: 2) ? 0.86 : 0.66, height: 13)
                        bar(width: 0.34, height: 8)
                    }
                    .padding(UIScale.pt(card ? 12 : 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetBar(
                        cornerRadius: card ? 12 : 8,
                        fill: DashSkin.paper2(dark).opacity(0.45),
                        stroke: DashSkin.line(dark).opacity(0.5))
                }
            }
        }
        .accessibilityLabel("Loading")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(DashSkin.inkFaint(dark).opacity(0.28))
                .frame(width: proxy.size.width * width, height: UIScale.pt(height))
        }
        .frame(height: UIScale.pt(height))
    }
}
