import Foundation

enum AppMaintenanceUpdatesState: Equatable {
    case checking
    case failed
    case neverChecked
    case upToDate
    case noMatches
    case list

    init(
        loading: Bool, checking: Bool, hasUpdates: Bool, matchesFilter: Bool, hasError: Bool,
        checkedBefore: Bool
    ) {
        if hasUpdates {
            self = matchesFilter ? .list : .noMatches
        } else if loading || checking {
            self = .checking
        } else if hasError {
            self = .failed
        } else if checkedBefore {
            self = .upToDate
        } else {
            self = .neverChecked
        }
    }
}

enum AppMaintenanceRefresh {
    static func interval(busy: Bool) -> Duration { busy ? .seconds(1) : .seconds(5) }
}

extension AppMaintenanceSection {
    var summary: String {
        switch self {
        case .updates:
            "Checks your apps and Homebrew for newer versions. Nothing installs until you choose to run it."
        case .removal:
            "Pick an app to see it and the files it left behind. Nothing moves until you confirm, and everything goes to the Trash."
        case .history:
            "A record of past update runs and whether each one worked."
        }
    }
}
