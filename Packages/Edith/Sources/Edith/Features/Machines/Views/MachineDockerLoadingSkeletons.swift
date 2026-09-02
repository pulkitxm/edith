import EdithKit
import SwiftUI

struct MachineProcessRowsSkeleton: View {
    var rows = 8

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { index in
                    HStack(spacing: UIScale.pt(10)) {
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            SkeletonBlock(
                                width: index.isMultiple(of: 3) ? 112 : 168,
                                height: 10,
                                corner: 2
                            )
                            SkeletonBlock(width: index.isMultiple(of: 2) ? 214 : 276, height: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SkeletonBlock(width: 58, height: 9)
                            .frame(width: UIScale.pt(80), alignment: .leading)
                        SkeletonBlock(width: 34, height: 9)
                            .frame(width: UIScale.pt(56), alignment: .trailing)
                        SkeletonBlock(width: 52, height: 9)
                            .frame(width: UIScale.pt(80), alignment: .trailing)
                        SkeletonBlock(width: 12, height: 12, corner: 6)
                            .frame(width: UIScale.pt(20))
                    }
                    .padding(.vertical, UIScale.pt(6))
                    .padding(.horizontal, UIScale.pt(4))
                    if index < rows - 1 { Divider().opacity(0.25) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading processes")
    }
}

struct DockerContainerRowsSkeleton: View {
    var rows = 5

    var body: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                HStack(spacing: UIScale.pt(6)) {
                    SkeletonBlock(width: 10, height: 10, corner: 2)
                    SkeletonBlock(width: 92, height: 9, corner: 2)
                    SkeletonBlock(width: 12, height: 9, corner: 2)
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 20, height: 16, corner: 5)
                }
                .padding(.horizontal, UIScale.pt(16))
                .padding(.vertical, UIScale.pt(6))
                ForEach(0..<rows, id: \.self) { index in
                    HStack(spacing: UIScale.pt(12)) {
                        SkeletonBlock(width: 8, height: 8, corner: 4)
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            SkeletonBlock(width: index.isMultiple(of: 2) ? 124 : 168, height: 11)
                            SkeletonBlock(width: index.isMultiple(of: 3) ? 184 : 224, height: 8)
                        }
                        .frame(width: UIScale.pt(230), alignment: .leading)
                        SkeletonBlock(width: 112, height: 9)
                            .frame(width: UIScale.pt(150), alignment: .leading)
                        SkeletonBlock(width: 92, height: 18, corner: 9)
                            .frame(width: UIScale.pt(160), alignment: .leading)
                        SkeletonBlock(width: 32, height: 9)
                            .frame(width: UIScale.pt(54), alignment: .trailing)
                        SkeletonBlock(width: 48, height: 9)
                            .frame(width: UIScale.pt(70), alignment: .trailing)
                        Spacer(minLength: 0)
                        HStack(spacing: UIScale.pt(4)) {
                            SkeletonBlock(width: 20, height: 20, corner: 6)
                            SkeletonBlock(width: 20, height: 20, corner: 6)
                        }
                    }
                    .padding(.horizontal, UIScale.pt(16))
                    .padding(.vertical, UIScale.pt(9))
                    Divider().opacity(0.2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading containers")
    }
}

struct DockerInspectSkeleton: View {
    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                ForEach(0..<7, id: \.self) { index in
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        SkeletonBlock(width: [42, 66, 82, 58, 48, 76, 52][index], height: 8)
                        SkeletonBlock(
                            width: [246, 312, 118, 204, 286, 332, 264][index],
                            height: 9,
                            corner: 2
                        )
                        if index == 5 || index == 6 {
                            SkeletonBlock(width: index == 5 ? 294 : 226, height: 9, corner: 2)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading container configuration")
    }
}

struct DockerProcessRowsSkeleton: View {
    var rows = 10

    var body: some View {
        SkeletonGroup {
            LazyVStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { index in
                    HStack(spacing: UIScale.pt(10)) {
                        SkeletonBlock(width: 26, height: 9)
                            .frame(width: UIScale.pt(56), alignment: .leading)
                        SkeletonBlock(width: index.isMultiple(of: 3) ? 34 : 52, height: 9)
                            .frame(width: UIScale.pt(80), alignment: .leading)
                        SkeletonBlock(
                            width: index.isMultiple(of: 2) ? 226 : 318,
                            height: 9,
                            corner: 2
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SkeletonBlock(width: 28, height: 9)
                            .frame(width: UIScale.pt(50), alignment: .trailing)
                        SkeletonBlock(width: 34, height: 9)
                            .frame(width: UIScale.pt(50), alignment: .trailing)
                    }
                    .padding(.horizontal, UIScale.pt(16))
                    .padding(.vertical, UIScale.pt(5))
                    Divider().opacity(0.15)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading container processes")
    }
}

struct DockerFileRowsSkeleton: View {
    var body: some View {
        SkeletonGroup {
            LazyVStack(spacing: 0) {
                ForEach(0..<11, id: \.self) { index in
                    HStack(spacing: UIScale.pt(10)) {
                        SkeletonBlock(width: 15, height: 15, corner: 3)
                        SkeletonBlock(width: index.isMultiple(of: 3) ? 112 : 176, height: 10)
                        Spacer(minLength: 0)
                        if !index.isMultiple(of: 3) {
                            SkeletonBlock(width: 48, height: 8)
                        }
                    }
                    .padding(.horizontal, UIScale.pt(16))
                    .padding(.vertical, UIScale.pt(5))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading container files")
    }
}
