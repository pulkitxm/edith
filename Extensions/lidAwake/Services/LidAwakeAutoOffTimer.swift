import Foundation

final class LidAwakeAutoOffTimer {
    var onExpire: (() -> Void)?
    var onTick: (() -> Void)?
    private(set) var deadline: Date?
    private var ticker: Timer?

    var remaining: TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSinceNow)
    }

    func start(minutes: Int) {
        cancel()
        deadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        startTicker()
    }

    func start(deadline: Date) {
        cancel()
        self.deadline = deadline
        startTicker()
    }

    private func startTicker() {
        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        ticker.tolerance = 5
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        deadline = nil
    }

    private func tick() {
        guard let deadline else { return }
        guard Date() < deadline else {
            cancel()
            onExpire?()
            return
        }
        onTick?()
    }
}
