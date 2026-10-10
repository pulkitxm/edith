import EdithExtensionSupport

enum HostNativeSurfaceRoute {
    static func section(provider: String, target: SurfaceTarget, tile: SurfaceTile) -> String? {
        guard target == .home, tile.widget.providerIDs == [provider] else { return nil }
        switch (provider, tile.widget) {
        case ("music", .music): return "music"
        case ("calendar", .calendar): return "calendar"
        case ("attention", .focus): return "focus"
        default: return nil
        }
    }
}
