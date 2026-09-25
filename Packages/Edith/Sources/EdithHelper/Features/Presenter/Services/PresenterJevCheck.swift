import EdithKit
import Foundation

final class PresenterJevCheck: @unchecked Sendable {
    static let interval: TimeInterval = 30
    static let threshold = 0.8
    static let windowLimit = 25
    static let titleLimit = 80
    static let purpose = "presenter.detect"
    static let question = "presenting"

    private let enabled: @Sendable () -> Bool
    private let decider: @Sendable () -> JevDeciding?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var askedAt: Date?
    private var answer: (fingerprint: String, reason: String?)?
    private var inFlight: Task<Void, Never>?

    init(
        enabled: @escaping @Sendable () -> Bool,
        decider: @escaping @Sendable () -> JevDeciding?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.enabled = enabled
        self.decider = decider
        self.now = now
    }

    static let live = PresenterJevCheck(
        enabled: { SharedDefaults.store.bool(forKey: AppStorageKeys.Presenter.askJev) },
        decider: { AgentJevDecider.configured() })

    func reason(for windows: [PresenterWindowInfo]) -> String? {
        guard enabled(), let app = PresenterRules.meetingApp(in: windows),
            let decider = decider()
        else { return nil }
        let fingerprint = Self.summary(of: windows)
        return lock.withLock {
            let moment = now()
            let due = askedAt.map { moment.timeIntervalSince($0) >= Self.interval } ?? true
            if answer?.fingerprint != fingerprint, inFlight == nil, due {
                askedAt = moment
                inFlight = Task {
                    await self.ask(decider, fingerprint: fingerprint, app: app)
                }
            }
            return answer?.reason
        }
    }

    func settle() async {
        let task = lock.withLock { inFlight }
        await task?.value
    }

    static func summary(of windows: [PresenterWindowInfo]) -> String {
        windows.lazy.filter(PresenterRules.isListed).prefix(windowLimit).map { window in
            let title = JevText.compact(window.title, limit: titleLimit)
            return "\(window.ownerName) | \(title) | \(Int(window.width))x\(Int(window.height))"
        }.joined(separator: "\n")
    }

    static func request(windows summary: String) -> JevRequest {
        JevRequest(
            state: .fields(["windows": summary]),
            questions: [
                question: .noul(
                    "The user is sharing their screen or presenting in a call, judging by `windows`."
                )
            ])
    }

    private func ask(_ decider: JevDeciding, fingerprint: String, app: String) async {
        let probability = try? await decider.decide(
            Self.request(windows: fingerprint), purpose: Self.purpose
        ).noul(Self.question)
        let reason =
            (probability ?? 0) >= Self.threshold ? "Jev: screen sharing in \(app)" : nil
        lock.withLock {
            answer = (fingerprint, reason)
            inFlight = nil
        }
    }
}
