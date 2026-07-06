struct PresenterDebouncer: Equatable {
    private(set) var active = false
    private var misses = 0

    mutating func record(hit: Bool) -> Bool {
        if hit {
            active = true
            misses = 0
        } else if active {
            misses += 1
            if misses >= 2 {
                active = false
                misses = 0
            }
        }
        return active
    }
}
