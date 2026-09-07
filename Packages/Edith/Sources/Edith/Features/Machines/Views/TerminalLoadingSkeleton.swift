import EdithKit
import SwiftUI

struct TerminalLoadingSkeleton: View {
    let palette: TerminalPalette

    private let lineWidths: [Double] = [176, 284, 132, 346, 224, 96, 302, 158, 256, 118]

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                ForEach(Array(lineWidths.enumerated()), id: \.offset) { index, width in
                    HStack(spacing: UIScale.pt(8)) {
                        if index.isMultiple(of: 3) {
                            SkeletonBlock(width: 10, height: 10, corner: 2)
                        }
                        SkeletonBlock(width: width, height: 10, corner: 2)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: UIScale.pt(8)) {
                    SkeletonBlock(width: 10, height: 10, corner: 2)
                    SkeletonBlock(width: 86, height: 10, corner: 2)
                    SkeletonBlock(width: 7, height: 14, corner: 1)
                }
            }
            .padding(.horizontal, UIScale.pt(16))
            .padding(.vertical, UIScale.pt(14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: palette.background))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading terminal")
    }
}
