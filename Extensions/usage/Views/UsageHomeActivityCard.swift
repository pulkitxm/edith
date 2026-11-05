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
                ActivityCalendarSkeleton(fillsWidth: true)
            } else {
                Text("No activity yet. Open Agent Usage to collect your history.")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
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
