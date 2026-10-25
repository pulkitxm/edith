import EdithExtensionSupport
import EdithExtensionUI
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
        PageCard(title: title) {
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
                PageCard(title: "Host") {
                    VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                        SkeletonBlock(width: 168, height: 10)
                        SkeletonBlock(width: 244, height: 10)
                    }
                }
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
