import EdithKit
import SwiftUI

struct GitHubRepositoryListSkeleton: View {
    var rows = 6
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<max(rows, 0), id: \.self) { index in
                    GitHubRepositorySkeletonRow(index: index)
                    if index < rows - 1 { Divider().opacity(0.18) }
                }
            }
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(12))
                    .stroke(DashSkin.line(dark), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GitHubRepositorySkeletonRow: View {
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            SkeletonBlock(width: 32, height: 32, corner: 8)
            VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                HStack {
                    SkeletonBlock(width: index.isMultiple(of: 3) ? 132 : 172, height: 12)
                    Spacer(minLength: UIScale.pt(16))
                    SkeletonBlock(width: 58, height: 18, corner: 7)
                }
                SkeletonBlock(width: index.isMultiple(of: 2) ? 238 : 292, height: 9)
                HStack(spacing: UIScale.pt(7)) {
                    SkeletonBlock(width: 8, height: 8, corner: 4)
                    SkeletonBlock(width: 54, height: 8)
                    SkeletonBlock(width: 42, height: 8)
                    SkeletonBlock(width: 68, height: 8)
                }
            }
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(12))
    }
}

struct GitHubTreeSkeleton: View {
    var rows = 12
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<max(rows, 0), id: \.self) { index in
                    HStack(spacing: UIScale.pt(9)) {
                        SkeletonBlock(width: 15, height: 15, corner: 4)
                        SkeletonBlock(
                            width: index.isMultiple(of: 4) ? 106 : 164, height: 10)
                        Spacer(minLength: UIScale.pt(14))
                        SkeletonBlock(
                            width: index.isMultiple(of: 3) ? 126 : 186, height: 9)
                        SkeletonBlock(width: 62, height: 9)
                    }
                    .padding(.horizontal, UIScale.pt(12))
                    .padding(.vertical, UIScale.pt(7))
                    if index < rows - 1 { Divider().opacity(0.16) }
                }
            }
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        }
        .accessibilityHidden(true)
    }
}

struct GitHubBrowserFileHeaderSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                HStack(spacing: UIScale.pt(7)) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBlock(width: 22, height: 22, corner: 7)
                    }
                    SkeletonBlock(height: 24, corner: 8)
                        .frame(maxWidth: .infinity)
                    SkeletonBlock(width: 26, height: 22, corner: 7)
                }
                .padding(.horizontal, UIScale.pt(12))
                .padding(.vertical, UIScale.pt(8))
                Divider().opacity(0.22)
                VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                    HStack(spacing: UIScale.pt(6)) {
                        SkeletonBlock(width: 64, height: 9)
                        SkeletonBlock(width: 8, height: 9, corner: 3)
                        SkeletonBlock(width: 88, height: 9)
                        SkeletonBlock(width: 8, height: 9, corner: 3)
                        SkeletonBlock(width: 112, height: 9)
                    }
                    HStack(spacing: UIScale.pt(9)) {
                        SkeletonBlock(width: 18, height: 18, corner: 4)
                        SkeletonBlock(width: 184, height: 13)
                        Spacer(minLength: UIScale.pt(12))
                        SkeletonBlock(width: 72, height: 24, corner: 7)
                        SkeletonBlock(width: 88, height: 24, corner: 7)
                    }
                }
                .padding(.horizontal, UIScale.pt(14))
                .padding(.vertical, UIScale.pt(11))
            }
            .background(DashSkin.paper2(dark))
        }
        .accessibilityHidden(true)
    }
}

struct GitHubCodeSkeleton: View {
    var rows = 18
    let dark: Bool

    private let lineWidths: [Double] = [210, 320, 152, 386, 264, 116, 344, 188]

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<max(rows, 0), id: \.self) { index in
                    HStack(spacing: 0) {
                        SkeletonBlock(width: 22, height: 8, corner: 3)
                            .frame(width: UIScale.pt(48), alignment: .trailing)
                            .padding(.trailing, UIScale.pt(10))
                        Divider().opacity(0.2)
                        HStack(spacing: 0) {
                            Color.clear.frame(width: UIScale.pt(Double(index % 4) * 12))
                            SkeletonBlock(
                                width: lineWidths[index % lineWidths.count], height: 8, corner: 3)
                        }
                        .padding(.leading, UIScale.pt(12))
                        Spacer(minLength: 0)
                    }
                    .frame(height: UIScale.pt(22))
                }
            }
            .padding(.vertical, UIScale.pt(8))
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        }
        .accessibilityHidden(true)
    }
}

struct GitHubCommitHistorySkeleton: View {
    var rows = 7
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<max(rows, 0), id: \.self) { index in
                    HStack(spacing: UIScale.pt(11)) {
                        SkeletonBlock(width: 28, height: 28, corner: 14)
                        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                            SkeletonBlock(
                                width: index.isMultiple(of: 3) ? 168 : 238, height: 10)
                            HStack(spacing: UIScale.pt(6)) {
                                SkeletonBlock(width: 82, height: 8)
                                SkeletonBlock(width: 56, height: 8)
                            }
                        }
                        Spacer(minLength: UIScale.pt(12))
                        SkeletonBlock(width: 58, height: 20, corner: 6)
                        SkeletonBlock(width: 64, height: 8)
                    }
                    .padding(.horizontal, UIScale.pt(14))
                    .padding(.vertical, UIScale.pt(10))
                    if index < rows - 1 { Divider().opacity(0.18) }
                }
            }
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        }
        .accessibilityHidden(true)
    }
}
