import EdithKit
import SwiftUI

struct CodeStatsReportSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                SkeletonBlock(width: 360, height: 24, corner: 7)
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: UIScale.pt(170)), spacing: UIScale.pt(10))
                    ],
                    spacing: UIScale.pt(10)
                ) {
                    ForEach(0..<5, id: \.self) { _ in CodeStatsTileSkeleton(dark: dark) }
                }
                CodeStatsCardSkeleton(title: "Contributions", dark: dark) {
                    HStack(spacing: UIScale.pt(3)) {
                        ForEach(0..<40, id: \.self) { _ in
                            VStack(spacing: UIScale.pt(3)) {
                                ForEach(0..<7, id: \.self) { _ in
                                    SkeletonBlock(width: 14, height: 14, corner: 3)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
                ForEach(["Output over time", "Commits per repository", "Languages"], id: \.self) {
                    title in
                    CodeStatsCardSkeleton(title: title, dark: dark) {
                        HStack(alignment: .bottom, spacing: UIScale.pt(6)) {
                            ForEach(0..<16, id: \.self) { index in
                                SkeletonBlock(height: Double(30 + index * 37 % 140), corner: 3)
                            }
                        }
                        .frame(height: UIScale.pt(180), alignment: .bottom)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading code stats")
    }
}

private struct CodeStatsTileSkeleton: View {
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            SkeletonBlock(width: 80, height: 9)
            SkeletonBlock(width: 96, height: 22, corner: 5)
            SkeletonBlock(width: 120, height: 9)
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .edithSurface(cornerRadius: 14)
    }
}

private struct CodeStatsCardSkeleton<Content: View>: View {
    let title: String
    let dark: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        SkinCard(title: title, dark: dark) {
            content()
        }
    }
}
