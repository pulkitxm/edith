import Foundation
import Testing

@testable import EdithKit

private final class LimitsAnnouncementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [Notification.Name] = []

    func append(_ name: Notification.Name) {
        lock.withLock { names.append(name) }
    }

    var count: Int { lock.withLock { names.count } }
}

@Suite struct LimitsProviderCollectionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func providerBackoffKeepsOtherProvidersFreshAndExpiresIndependently() async {
        let session = LimitsRefreshSession()
        let announcements = LimitsAnnouncementRecorder()
        var fetched: [LimitProvider] = []
        let limited = LimitsProviderSnapshot(
            provider: .claude, session: nil, week: nil, error: "Rate limited")
        let healthy = LimitsProviderSnapshot(
            provider: .codex, session: LimitWindow(percent: 15, resetsAt: nil), week: nil)
        let first = await LimitsCollector.collect(
            providers: [.claude, .codex], refreshSession: session, now: now,
            announce: announcements.append
        ) { provider in
            fetched.append(provider)
            return provider == .claude
                ? (limited, now.addingTimeInterval(300)) : (healthy, nil)
        }
        #expect(first.failure == "Rate limited")
        #expect(fetched == [.claude, .codex])
        fetched = []
        let second = await LimitsCollector.collect(
            providers: [.claude, .codex], refreshSession: session,
            now: now.addingTimeInterval(100), announce: announcements.append
        ) { provider in
            fetched.append(provider)
            return (healthy, nil)
        }
        #expect(fetched == [.codex])
        #expect(second.providers == [limited, healthy])
        fetched = []
        _ = await LimitsCollector.collect(
            providers: [.claude, .codex], refreshSession: session,
            now: now.addingTimeInterval(301), announce: announcements.append
        ) { provider in
            fetched.append(provider)
            return (
                LimitsProviderSnapshot(
                    provider: provider, session: LimitWindow(percent: 20, resetsAt: nil),
                    week: nil), nil
            )
        }
        #expect(fetched == [.claude, .codex])
        #expect(announcements.count == 3)
    }

    @Test func totalFailurePublishesCompletionAndTheNextRequestCanRecover() async {
        let session = LimitsRefreshSession()
        let announcements = LimitsAnnouncementRecorder()
        let failed = await LimitsCollector.collect(
            providers: [.claude, .codex], refreshSession: session, now: now,
            announce: announcements.append
        ) { provider in
            (
                LimitsProviderSnapshot(
                    provider: provider, session: nil, week: nil, error: "Offline"), nil
            )
        }
        #expect(failed.failure == "Offline")
        #expect(announcements.count == 1)
        let recovered = await LimitsCollector.collect(
            providers: [.claude, .codex], refreshSession: session,
            now: now.addingTimeInterval(60), announce: announcements.append
        ) { provider in
            (
                LimitsProviderSnapshot(
                    provider: provider, session: LimitWindow(percent: 23, resetsAt: nil),
                    week: nil), nil
            )
        }
        #expect(recovered.failure == nil)
        #expect(recovered.providers.allSatisfy { $0.session?.percent == 23 })
        #expect(announcements.count == 2)
    }

    @Test func disablingABackedOffProviderRemovesItsError() async {
        let session = LimitsRefreshSession()
        _ = await LimitsCollector.collect(
            providers: [.claude], refreshSession: session, now: now, announce: { _ in }
        ) { provider in
            (
                LimitsProviderSnapshot(
                    provider: provider, session: nil, week: nil, error: "Rate limited"),
                now.addingTimeInterval(300)
            )
        }
        let snapshot = await LimitsCollector.collect(
            providers: [.codex], refreshSession: session,
            now: now.addingTimeInterval(1), announce: { _ in }
        ) { provider in
            (LimitsProviderSnapshot(provider: provider, session: nil, week: nil), nil)
        }
        #expect(snapshot.failure == nil)
        #expect(snapshot.providers.map(\.provider) == [.codex])
    }
}
