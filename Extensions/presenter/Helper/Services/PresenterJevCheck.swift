import EdithExtensionSupport
import Foundation

final class PresenterJevCheck: @unchecked Sendable {
    static let interval: TimeInterval = 30
    static let threshold = 0.8
    static let windowLimit = 25
    static let titleLimit = 80
    static let purpose = "presenter.detect"
    static let question = "presenting"

    private let enabled: @Sendable () -> Bool
    private let decider: @Sendable () -> PresenterDeciding?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var askedAt: Date?
    private var answer: (fingerprint: String, reason: String?)?
    private var inFlight: Task<Void, Never>?
    private var stopped = false

    init(
        enabled: @escaping @Sendable () -> Bool,
        decider: @escaping @Sendable () -> PresenterDeciding?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.enabled = enabled
        self.decider = decider
        self.now = now
    }

    static var live: PresenterJevCheck {
        PresenterJevCheck(
            enabled: { SharedDefaults.store.bool(forKey: AppStorageKeys.Presenter.askJev) },
            decider: { PresenterJevClient.configured() })
    }

    func reason(for windows: [PresenterWindowInfo]) -> String? {
        guard enabled(), let app = PresenterRules.meetingApp(in: windows),
            let decider = decider()
        else { return nil }
        return lock.withLock {
            guard !stopped else { return nil }
            let moment = now()
            let due = askedAt.map { moment.timeIntervalSince($0) >= Self.interval } ?? true
            guard inFlight == nil, due else { return answer?.reason }
            let fingerprint = Self.summary(of: windows)
            if answer?.fingerprint != fingerprint {
                askedAt = moment
                inFlight = Task {
                    await self.ask(decider, fingerprint: fingerprint, app: app)
                }
            }
            return answer?.reason
        }
    }

    func shutdown() {
        let task = lock.withLock {
            stopped = true
            defer { inFlight = nil; answer = nil }
            return inFlight
        }
        task?.cancel()
    }

    func settle() async {
        let task = lock.withLock { inFlight }
        await task?.value
    }

    static func summary(of windows: [PresenterWindowInfo]) -> String {
        windows.lazy.filter(PresenterRules.isListed).prefix(windowLimit).map { window in
            let title = PresenterText.compact(window.title, limit: titleLimit)
            return "\(window.ownerName) | \(title) | \(Int(window.width))x\(Int(window.height))"
        }.joined(separator: "\n")
    }

    private func ask(_ decider: PresenterDeciding, fingerprint: String, app: String) async {
        let probability = try? await decider.probability(windows: fingerprint)
        let reason =
            (probability ?? 0) >= Self.threshold ? "Jev: screen sharing in \(app)" : nil
        lock.withLock {
            guard !stopped, !Task.isCancelled else { return }
            answer = (fingerprint, reason)
            inFlight = nil
        }
    }
}
