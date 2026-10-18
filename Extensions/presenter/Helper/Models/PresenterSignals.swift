struct PresenterSignals: Equatable {
    struct Verdict: Equatable {
        let active: Bool
        let reason: String?
    }

    var windowReason: String?
    var recording = false
    var sharing = false
    var mirroring = false
    private(set) var paused: Bool
    private var debouncer = PresenterDebouncer()
    private var reason: String?

    init(paused: Bool) {
        self.paused = paused
    }

    var hit: Bool { windowReason != nil || recording || sharing || mirroring }

    mutating func pause() {
        paused = true
    }

    mutating func evaluate(completedScan: Bool) -> Verdict {
        if paused {
            guard !PresenterPauseGate.stillPaused(hit: hit) else {
                return Verdict(active: false, reason: nil)
            }
            paused = false
        }
        let candidate =
            windowReason
            ?? (recording ? "Screen recording detected" : nil)
            ?? (sharing ? "Screen Sharing detected" : nil)
            ?? (mirroring ? "Mirrored display detected" : nil)
        let active = hit || completedScan ? debouncer.record(hit: hit) : debouncer.active
        reason = active ? (candidate ?? reason) : nil
        return Verdict(active: active, reason: reason)
    }
}
