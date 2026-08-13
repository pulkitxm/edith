import EdithKit
import SwiftUI

struct SkeletonBlock: View {
    var width: Double?
    var height: Double = 12
    var corner: Double = 5
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmering = false

    private var dark: Bool { scheme == .dark }

    private var scaledWidth: CGFloat? {
        guard let width else { return nil }
        return CGFloat(UIScale.pt(width))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: UIScale.pt(corner))
            .fill(DashSkin.line(dark).opacity(0.55))
            .frame(width: scaledWidth, height: UIScale.pt(height))
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [
                                .clear, DashSkin.inkFaint(dark).opacity(0.18), .clear,
                            ], startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.45)
                        .offset(x: shimmering ? proxy.size.width : -proxy.size.width * 0.45)
                    }
                    .mask(RoundedRectangle(cornerRadius: UIScale.pt(corner)))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmering = true
                }
            }
    }
}

private struct SkeletonCard<Content: View>: View {
    let dark: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(UIScale.pt(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(14)).strokeBorder(DashSkin.line(dark))
            }
    }
}

struct MetricCardSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonCard(dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(alignment: .firstTextBaseline) {
                    SkeletonBlock(width: 34, height: 8)
                    Spacer()
                    SkeletonBlock(width: 54, height: 18, corner: 4)
                }
                SkeletonBlock(height: 6, corner: 3)
                SkeletonBlock(height: 46, corner: 8)
                SkeletonBlock(width: 78, height: 9)
            }
        }
    }
}

struct BannerSkeleton: View {
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            SkeletonBlock(width: 13, height: 13, corner: 6.5)
            SkeletonBlock(width: 108, height: 11)
            Spacer(minLength: 0)
            SkeletonBlock(width: 150, height: 9)
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(10))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark))
        }
    }
}

struct MeterRowsSkeleton: View {
    let title: String
    let rows: Int
    let dark: Bool

    var body: some View {
        SkinCard(title: title, dark: dark) {
            VStack(spacing: UIScale.pt(10)) {
                ForEach(0..<rows, id: \.self) { index in
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        HStack {
                            SkeletonBlock(width: index.isMultiple(of: 2) ? 68 : 112, height: 10)
                            Spacer()
                            SkeletonBlock(width: 96, height: 9)
                        }
                        SkeletonBlock(height: 6, corner: 3)
                    }
                }
            }
        }
    }
}

struct MachineOverviewSkeleton: View {
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            BannerSkeleton(dark: dark)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: UIScale.pt(12)),
                    GridItem(.flexible(), spacing: UIScale.pt(12)),
                ], spacing: UIScale.pt(12)
            ) {
                MetricCardSkeleton(dark: dark)
                MetricCardSkeleton(dark: dark)
            }
            MeterRowsSkeleton(title: "Storage", rows: 2, dark: dark)
            SkinCard(title: "Host", dark: dark) {
                VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                    SkeletonBlock(width: 168, height: 10)
                    SkeletonBlock(width: 244, height: 10)
                }
            }
        }
    }
}

struct FleetHomeSkeleton: View {
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            BannerSkeleton(dark: dark)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: UIScale.pt(12)),
                    GridItem(.flexible(), spacing: UIScale.pt(12)),
                ], spacing: UIScale.pt(12)
            ) {
                MetricCardSkeleton(dark: dark)
                MetricCardSkeleton(dark: dark)
            }
            MeterRowsSkeleton(title: "Storage", rows: 2, dark: dark)
            SkinCard(title: "Machines", dark: dark) {
                VStack(spacing: UIScale.pt(0)) {
                    ForEach(0..<2, id: \.self) { index in
                        HStack(spacing: UIScale.pt(12)) {
                            SkeletonBlock(width: 15, height: 15, corner: 4)
                            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                SkeletonBlock(width: 84, height: 11)
                                SkeletonBlock(width: 116, height: 8)
                            }
                            .frame(width: UIScale.pt(150), alignment: .leading)
                            ForEach(0..<3, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                    SkeletonBlock(width: 44, height: 7)
                                    SkeletonBlock(height: 6, corner: 3)
                                }
                            }
                            SkeletonBlock(width: 48, height: 9)
                        }
                        .padding(.vertical, UIScale.pt(11))
                        if index == 0 { Divider().opacity(0.25) }
                    }
                }
            }
        }
    }
}

struct FinderSkeleton: View {
    let mode: FileViewMode
    let dark: Bool

    var body: some View {
        if mode == .icon {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: UIScale.pt(102)), spacing: UIScale.pt(8))
                    ],
                    spacing: UIScale.pt(10)
                ) {
                    ForEach(0..<18, id: \.self) { index in
                        VStack(spacing: UIScale.pt(6)) {
                            SkeletonBlock(width: 68, height: 68, corner: 10)
                            SkeletonBlock(width: index.isMultiple(of: 3) ? 44 : 62, height: 9)
                        }
                        .frame(width: UIScale.pt(98))
                        .padding(.vertical, UIScale.pt(6))
                    }
                }
                .padding(UIScale.pt(12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 0) {
                ForEach(0..<14, id: \.self) { index in
                    HStack(spacing: UIScale.pt(8)) {
                        SkeletonBlock(width: 16, height: 16, corner: 4)
                        SkeletonBlock(width: index.isMultiple(of: 4) ? 118 : 176, height: 10)
                        Spacer(minLength: 0)
                        SkeletonBlock(width: 96, height: 9)
                        SkeletonBlock(width: 54, height: 9)
                        SkeletonBlock(width: 68, height: 9)
                    }
                    .padding(.horizontal, UIScale.pt(12))
                    .padding(.vertical, UIScale.pt(5))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, UIScale.pt(4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct ListRowsSkeleton: View {
    var rows: Int = 6
    var showsLeadingDot = true
    let dark: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { index in
                HStack(spacing: UIScale.pt(12)) {
                    if showsLeadingDot {
                        SkeletonBlock(width: 8, height: 8, corner: 4)
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        SkeletonBlock(width: index.isMultiple(of: 3) ? 96 : 132, height: 11)
                        SkeletonBlock(width: 168, height: 8)
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 92, height: 9)
                    SkeletonBlock(width: 46, height: 9)
                }
                .padding(.horizontal, UIScale.pt(16))
                .padding(.vertical, UIScale.pt(9))
                Divider().opacity(0.18)
            }
        }
    }
}
