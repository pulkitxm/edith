import EdithExtensionUI
import SwiftUI

struct FinderSkeleton: View {
    let mode: FileViewMode
    let iconSize: Double
    let dark: Bool

    init(mode: FileViewMode, iconSize: Double = 68, dark: Bool) {
        self.mode = mode
        self.iconSize = iconSize
        self.dark = dark
    }

    var body: some View {
        SkeletonGroup {
            if mode == .icon {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: UIScale.pt(iconSize + 34)),
                                spacing: UIScale.pt(12))
                        ],
                        spacing: UIScale.pt(14)
                    ) {
                        ForEach(0..<18, id: \.self) { index in
                            VStack(spacing: UIScale.pt(6)) {
                                SkeletonBlock(width: iconSize, height: iconSize, corner: 10)
                                SkeletonBlock(width: index.isMultiple(of: 3) ? 44 : 62, height: 9)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, UIScale.pt(6))
                        }
                    }
                    .padding(UIScale.pt(16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: UIScale.pt(10)) {
                        SkeletonBlock(width: 48, height: 8, corner: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, UIScale.pt(30))
                        SkeletonBlock(width: 74, height: 8, corner: 2)
                            .frame(width: UIScale.pt(130), alignment: .trailing)
                        SkeletonBlock(width: 30, height: 8, corner: 2)
                            .frame(width: UIScale.pt(78), alignment: .trailing)
                        SkeletonBlock(width: 32, height: 8, corner: 2)
                            .frame(width: UIScale.pt(92), alignment: .trailing)
                    }
                    .padding(.horizontal, UIScale.pt(12))
                    .padding(.vertical, UIScale.pt(5))
                    Divider().opacity(0.4)
                    ForEach(0..<14, id: \.self) { index in
                        HStack(spacing: UIScale.pt(10)) {
                            SkeletonBlock(width: 16, height: 16, corner: 4)
                            SkeletonBlock(width: index.isMultiple(of: 4) ? 118 : 176, height: 10)
                            Spacer(minLength: 0)
                            SkeletonBlock(width: 96, height: 9)
                                .frame(width: UIScale.pt(130), alignment: .trailing)
                            SkeletonBlock(width: 48, height: 9)
                                .frame(width: UIScale.pt(78), alignment: .trailing)
                            SkeletonBlock(width: 62, height: 9)
                                .frame(width: UIScale.pt(92), alignment: .trailing)
                        }
                        .padding(.horizontal, UIScale.pt(12))
                        .padding(.vertical, UIScale.pt(5))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}
