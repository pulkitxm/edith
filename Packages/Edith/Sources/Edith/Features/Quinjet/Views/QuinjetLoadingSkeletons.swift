import EdithKit
import SwiftUI

struct QuinjetProjectGridSkeleton: View {
    let dark: Bool
    var rows = 6

    var body: some View {
        SkeletonGroup {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: UIScale.pt(330)), spacing: UIScale.pt(14))
                    ],
                    spacing: UIScale.pt(14)
                ) {
                    ForEach(0..<rows, id: \.self) { index in
                        HStack(spacing: UIScale.pt(12)) {
                            HStack(spacing: UIScale.pt(11)) {
                                SkeletonBlock(width: 18, height: 18, corner: 4)
                                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                    SkeletonBlock(
                                        width: index.isMultiple(of: 2) ? 112 : 148, height: 12)
                                    SkeletonBlock(
                                        width: index.isMultiple(of: 3) ? 178 : 224, height: 9)
                                }
                                Spacer(minLength: 0)
                            }
                            VStack(alignment: .trailing, spacing: UIScale.pt(4)) {
                                SkeletonBlock(width: 78, height: 10)
                                SkeletonBlock(width: 72, height: 8)
                            }
                            .frame(minWidth: UIScale.pt(118), alignment: .trailing)
                            .padding(.horizontal, UIScale.pt(12))
                            .padding(.vertical, UIScale.pt(10))
                            .overlay {
                                RoundedRectangle(cornerRadius: UIScale.pt(9))
                                    .strokeBorder(DashSkin.lineStrong(dark))
                            }
                        }
                        .padding(UIScale.pt(14))
                        .background(
                            DashSkin.paper2(dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(12))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: UIScale.pt(12))
                                .strokeBorder(DashSkin.lineStrong(dark))
                        }
                    }
                }
                .padding(.top, UIScale.pt(2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading recent projects")
    }
}

struct QuinjetWorktreePickerSkeleton: View {
    let dark: Bool
    var rows = 4

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(spacing: UIScale.pt(8)) {
                    SkeletonBlock(width: 126, height: 11)
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 68, height: 9)
                }
                Divider().opacity(0.5)
                LazyVStack(spacing: UIScale.pt(3)) {
                    ForEach(0..<rows, id: \.self) { index in
                        HStack(spacing: UIScale.pt(9)) {
                            SkeletonBlock(width: 15, height: 15, corner: 7.5)
                            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                SkeletonBlock(
                                    width: index.isMultiple(of: 2) ? 102 : 136, height: 10)
                                SkeletonBlock(
                                    width: index.isMultiple(of: 3) ? 184 : 226, height: 8)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, UIScale.pt(8))
                        .padding(.vertical, UIScale.pt(7))
                        .frame(minHeight: UIScale.pt(42))
                    }
                }
            }
            .padding(UIScale.pt(12))
            .frame(width: UIScale.pt(330))
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading worktrees")
    }
}

struct QuinjetFolderBrowserSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            ScrollView {
                LazyVStack(spacing: UIScale.pt(5)) {
                    HStack(spacing: UIScale.pt(11)) {
                        SkeletonBlock(width: 18, height: 18, corner: 4)
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            SkeletonBlock(width: 142, height: 11)
                            SkeletonBlock(width: 238, height: 9)
                        }
                        Spacer(minLength: 0)
                        SkeletonBlock(width: 38, height: 8)
                    }
                    .padding(.horizontal, UIScale.pt(12))
                    .frame(minHeight: UIScale.pt(54))
                    .folderRowCard(dark: dark)

                    ForEach(0..<6, id: \.self) { index in
                        HStack(spacing: UIScale.pt(11)) {
                            SkeletonBlock(width: 18, height: 18, corner: 4)
                            SkeletonBlock(
                                width: index.isMultiple(of: 2) ? 126 : 174, height: 11)
                            Spacer(minLength: 0)
                            SkeletonBlock(width: 9, height: 14, corner: 3)
                        }
                        .padding(.horizontal, UIScale.pt(12))
                        .frame(minHeight: UIScale.pt(44))
                        .folderRowCard(dark: dark)
                    }
                }
                .padding(.top, UIScale.pt(2))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading folders")
    }
}

private extension View {
    func folderRowCard(dark: Bool) -> some View {
        background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .strokeBorder(DashSkin.lineStrong(dark))
            }
    }
}
