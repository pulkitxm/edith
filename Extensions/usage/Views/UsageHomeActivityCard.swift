import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct UsageHomeActivityCard: View {
    let tile: SurfaceTile
    @State private var model: DashboardModel

    @MainActor init(tile: SurfaceTile, model: DashboardModel? = nil) {
        self.tile = tile
        _model = State(initialValue: model ?? DashboardModel.shared)
    }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        PageCard(title: tile.displayTitle, note: "daily activity") {
            if model.homeUsage.hasDays {
                ActivityHeatmap(
                    days: model.homeUsage.calendarDays, scale: model.homeUsage.heatScale,
                    model: model, dark: scheme == .dark,
                    blur: UsagePresenterState.shared.active && UsagePresenterState.shared.money,
                    blurTokens: UsagePresenterState.shared.active
                        && UsagePresenterState.shared.usage)
            } else {
                PageLoading(
                    state: model.contentLoad.state, title: "No usage activity yet",
                    message: model.contentLoad.errorMessage ?? "Refresh Usage to collect activity.",
                    layout: .analytics, retry: { _ = try? UsageWorkerOperations.requestRefresh() }
                ) {
                    EmptyView()
                }
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
