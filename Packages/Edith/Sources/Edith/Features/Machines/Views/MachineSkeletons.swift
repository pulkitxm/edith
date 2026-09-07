import EdithKit
import SwiftUI

private struct SkeletonCard<Content: View>: View {
    let dark: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(UIScale.pt(14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetBar(cornerRadius: 14, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
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

struct NetworkMetricCardSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonCard(dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack {
                    SkeletonBlock(width: 86, height: 10, corner: 3)
                    Spacer()
                    SkeletonBlock(width: 13, height: 13, corner: 4)
                }
                NetworkSpeedLoadingSkeleton()
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
        .widgetBar(cornerRadius: 12, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
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
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                BannerSkeleton(dark: dark)
                MetricsGridLayout(spacing: UIScale.pt(12)) {
                    MetricCardSkeleton(dark: dark)
                    MetricCardSkeleton(dark: dark)
                    NetworkMetricCardSkeleton(dark: dark)
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
}

struct FleetHomeSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
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
}

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

struct ListRowsSkeleton: View {
    var rows: Int = 6
    var showsLeadingDot = true
    let dark: Bool

    var body: some View {
        SkeletonGroup {
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
}
