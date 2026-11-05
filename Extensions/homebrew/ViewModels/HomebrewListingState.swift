enum HomebrewListingState: Equatable {
    case notInstalled
    case discoverPrompt
    case noSearchResults
    case nothingInstalled
    case noMatchingFilters
    case packages

    init(
        available: Bool?, mode: HomebrewPageMode, hasQuery: Bool, filtersActive: Bool,
        hasPackages: Bool
    ) {
        if available == false {
            self = .notInstalled
        } else if hasPackages {
            self = .packages
        } else if mode == .search {
            self = hasQuery ? .noSearchResults : .discoverPrompt
        } else {
            self = filtersActive ? .noMatchingFilters : .nothingInstalled
        }
    }
}
