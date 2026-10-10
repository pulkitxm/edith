import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct UsageHomeScene: View {
    let tile: SurfaceTile
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        Group {
            switch tile.widget {
            case .activity: UsageHomeActivityCard(tile: tile)
            case .usage: UsageHomeUsageCard(tile: tile)
            case .limits: RateLimitsDialsView(dark: scheme == .dark, showsJumpLink: true)
            default: EmptyView()
            }
        }
        .environment(
            \.surfacePresentation,
            SurfacePresentation(tile: tile, layout: SurfaceLayout(tiles: [tile]))
        )
        .environment(\.compactLayout, compact || tile.dense)
    }
}
