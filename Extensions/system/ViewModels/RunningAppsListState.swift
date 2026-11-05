enum RunningAppsListState: Equatable {
    case apps
    case noneRunning
    case noMatches

    init(hasApps: Bool, hasVisibleApps: Bool, searching: Bool) {
        if hasVisibleApps {
            self = .apps
        } else if searching && hasApps {
            self = .noMatches
        } else {
            self = .noneRunning
        }
    }
}
