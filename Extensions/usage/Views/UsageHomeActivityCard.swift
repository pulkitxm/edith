import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct UsageHomeActivityCard: View {
    let tile: SurfaceTile
    @Environment(\.usageUIClient) private var client
    @State private var model: DashboardModel
    private let presenter: UsagePresenterState

    @MainActor init(
        tile: SurfaceTile, model: DashboardModel? = nil, presenter: UsagePresenterState? = nil
    ) {
        self.tile = tile
        self.presenter = presenter ?? UsagePresenterState.shared
        _model = State(initialValue: model ?? DashboardModel.shared)
    }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        PageCard(title: tile.title.isEmpty ? "Activity" : tile.displayTitle, note: "daily activity")
        {
            if model.homeUsage.hasDays {
                ActivityHeatmap(
                    days: model.homeUsage.calendarDays, scale: model.homeUsage.heatScale,
                    model: model, dark: scheme == .dark,
                    blur: presenter.active && presenter.money,
                    blurTokens: presenter.active
                        && presenter.usage)
            } else if !model.loadAttempted {
                UsageActivityHeatmapSkeleton()
            } else {
                Text("No usage activity yet").foregroundStyle(.secondary)
            }
        }
        .pageTask { await model.load() }
        .pageTask {
            for await _ in NotificationCenter.default.notifications(named: UsageEvents.usageUpdated)
            {
                guard !Task.isCancelled else { return }
                await model.load()
            }
        }
    }
}

private struct UsageActivityHeatmapSkeleton: View {
    var body: some View {
        SkeletonGroup {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: UIScale.pt(3)) {
                    ForEach(0..<18, id: \.self) { _ in
                        VStack(spacing: UIScale.pt(3)) {
                            SkeletonBlock(width: 14, height: 8, corner: 3)
                            ForEach(0..<7, id: \.self) { _ in
                                SkeletonBlock(width: 14, height: 14, corner: 3)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: UIScale.pt(137))
        }
        .accessibilityLabel("Loading activity")
    }
}
