import EdithKit
import SwiftUI

struct SEOAuditPageRowsSkeleton: View {
    let dark: Bool
    var rows = 3

    var body: some View {
        SkeletonGroup {
            VStack(spacing: UIScale.pt(8)) {
                ForEach(0..<rows, id: \.self) { index in
                    HStack(spacing: UIScale.pt(10)) {
                        SkeletonBlock(width: 14, height: 14, corner: 3)
                            .padding(.leading, UIScale.pt(14))
                        HStack(spacing: UIScale.pt(12)) {
                            SkeletonBlock(width: 25, height: 25, corner: 12.5)
                            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                                SkeletonBlock(
                                    width: index.isMultiple(of: 2) ? 178 : 238, height: 11)
                                SkeletonBlock(
                                    width: index.isMultiple(of: 3) ? 212 : 296, height: 9)
                            }
                            Spacer(minLength: UIScale.pt(8))
                            SkeletonBlock(width: 24, height: 16, corner: 8)
                            SkeletonBlock(width: 28, height: 10)
                            SkeletonBlock(width: 9, height: 14, corner: 3)
                        }
                        .padding(.trailing, UIScale.pt(14))
                        .frame(minHeight: UIScale.pt(58))
                    }
                    .background(
                        DashSkin.paper2(dark),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(12))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(12))
                            .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading audit pages")
    }
}

struct SEOAuditScoreTilesSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            HStack(spacing: UIScale.pt(8)) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(spacing: UIScale.pt(3)) {
                        SkeletonBlock(width: 24, height: 14, corner: 3)
                        SkeletonBlock(width: 28, height: 7, corner: 2)
                    }
                    .padding(.vertical, UIScale.pt(8))
                    .frame(maxWidth: .infinity)
                    .background(
                        DashSkin.paper2(dark),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Running Lighthouse")
    }
}

struct SEOAuditImageSkeleton: View {
    var body: some View {
        SkeletonReplica("Loading image preview") {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
