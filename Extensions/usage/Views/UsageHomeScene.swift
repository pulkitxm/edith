import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct UsageHomeScene: View {
    let tile: SurfaceTile
    let scene: UsageUIPresentation?

    init(tile: SurfaceTile, scene: UsageUIPresentation? = nil) {
        self.tile = tile; self.scene = scene
    }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        Group {
            switch tile.widget {
            case .activity:
                if let scene, scene.route.location == .notch {
                    UsageHomeUsageCard(tile: tile, scene: scene)
                } else {
                    UsageHomeActivityCard(
                        tile: tile, model: scene?.model, presenter: scene?.presenter)
                }
            case .usage: UsageHomeUsageCard(tile: tile, scene: scene)
            case .limits: if let scene { UsageHomeLimitsCard(tile: tile, scene: scene) }
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
