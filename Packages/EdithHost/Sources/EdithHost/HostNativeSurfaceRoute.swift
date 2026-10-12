import EdithExtensionSupport
import EdithExtensionUI

enum HostNativeSurfaceRoute {
    static func section(provider: String, target: SurfaceTarget, tile: SurfaceTile) -> String? {
        guard target == .home, tile.widget.providerIDs == [provider] else { return nil }
        switch (provider, tile.widget) {
        case ("music", .music): return "music"
        case ("calendar", .calendar): return "calendar"
        case ("attention", .focus): return "focus"
        case ("usage", .usage): return "usage"
        case ("usage", .activity): return "activity"
        case ("usage", .limits): return "limits"
        default: return nil
        }
    }

    static func request(
        target: SurfaceTarget, tile: SurfaceTile, presentation: SurfacePresentation?
    ) -> SurfaceSnapshotRequest {
        var resolved = tile
        if let presentation, presentation.tile == tile {
            resolved.paddingOverride = presentation.padding
            resolved.cornerOverride = presentation.cornerRadius
        }
        return SurfaceSnapshotRequest(target: target, tile: resolved)
    }
}
