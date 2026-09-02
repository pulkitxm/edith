import EdithKit
import SwiftUI

struct HerdrSkeleton: View {
    let dark: Bool
    var rows: Int = 3
    var card = true

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(card ? 8 : 2)) {
                ForEach(0..<rows, id: \.self) { index in
                    if card {
                        cardRow(index)
                    } else {
                        railRow(index)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Herdr sessions")
    }

    private func cardRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack(spacing: UIScale.pt(6)) {
                SkeletonBlock(width: 13, height: 13, corner: 4)
                SkeletonBlock(width: index.isMultiple(of: 2) ? 48 : 62, height: 9)
                Spacer(minLength: 0)
                SkeletonBlock(width: 34, height: 13, corner: 6.5)
            }
            SkeletonBlock(width: index.isMultiple(of: 2) ? 152 : 188, height: 12)
            SkeletonBlock(width: index.isMultiple(of: 3) ? 118 : 164, height: 9)
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBar(
            cornerRadius: 12,
            fill: DashSkin.paper2(dark).opacity(0.45),
            stroke: DashSkin.line(dark).opacity(0.5))
    }

    private func railRow(_ index: Int) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(8)) {
            SkeletonBlock(width: 13, height: 13, corner: 4)
                .padding(.top, UIScale.pt(2))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                SkeletonBlock(width: index.isMultiple(of: 2) ? 126 : 164, height: 11)
                SkeletonBlock(width: index.isMultiple(of: 3) ? 102 : 144, height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(8))
    }
}

struct HerdrBoardSkeleton: View {
    let dark: Bool
    let compact: Bool

    var body: some View {
        SkeletonGroup {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    ForEach(0..<4, id: \.self) { index in
                        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                            HStack(spacing: UIScale.pt(8)) {
                                SkeletonBlock(width: 7, height: 7, corner: 3.5)
                                SkeletonBlock(
                                    width: index.isMultiple(of: 2) ? 54 : 72, height: 10)
                                SkeletonBlock(width: 14, height: 9)
                            }
                            HerdrSkeleton(dark: dark, rows: index == 0 ? 3 : 1)
                        }
                        .frame(width: UIScale.pt(compact ? 220 : 240), alignment: .topLeading)
                        .frame(minHeight: UIScale.pt(220), alignment: .topLeading)
                    }
                }
                .pageContent(compact)
                .padding(.top, UIScale.pt(46))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Herdr board")
    }
}
