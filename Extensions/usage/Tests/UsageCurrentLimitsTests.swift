import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageCurrentLimitsTests {
    @Test @MainActor func failuresStayWithTheirAccountOrProviderAndDoNotRestoreHistory()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("limits-history.jsonl")
        var history = LimitsHistory(url: url)
        let appended = history.append(
            provider: .codex, session: nil, week: .init(percent: 80, resetsAt: nil))
        #expect(appended)
        let store = UsageStore(showMenuBar: false, historyURL: url)
        defer { store.shutdown() }
        let account = ClaudeAccountLimits(
            id: UUID(), name: "Sample account",
            limits: .init(
                provider: .claude, session: nil, week: nil,
                error: ClaudeLimitsReader.Failure.unauthorized.localizedDescription),
            refreshedAt: Date())
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: Date(),
            providers: [
                .init(provider: .codex, session: nil, week: nil, error: "Sample provider offline"),
                .init(provider: .grok, session: nil, week: .init(percent: 2, resetsAt: nil)),
            ], failure: account.limits.error, claudeAccounts: [account])
        await store.receiveLimitsSnapshot(snapshot)
        await store.reloadLimitsFromHistory()
        #expect(store.limitsError == nil)
        #expect(store.snapshot(for: .codex).error == "Sample provider offline")
        #expect(store.limits(for: .codex).week == nil)
        #expect(store.snapshot(for: .grok).error == nil)
        #expect(account.errorMessage?.contains("Reconnect subscription limits") == true)
        #expect(account.limits.reportedSlots.isEmpty)
        #expect(account.limits.unreportedSessionMessage == nil)
        let general = LimitsTopicSnapshot(
            refreshedAt: Date(), providers: [], failure: "Sample configuration unavailable")
        await store.receiveLimitsSnapshot(general)
        #expect(store.limitsError == general.failure)
    }

    @Test func successfulWeeklyOnlyResponsesExplainAnUnreportedSession() {
        for provider in [LimitProvider.claude, .codex] {
            let snapshot = LimitsProviderSnapshot(
                provider: provider, session: nil, week: .init(percent: 21, resetsAt: nil))
            #expect(snapshot.reportedSlots == [.week])
            #expect(
                snapshot.unreportedSessionMessage
                    == "No 5-hour window reported by \(provider.label).")
        }
        let failed = LimitsProviderSnapshot(
            provider: .codex, session: nil, week: nil, error: "Sample offline")
        #expect(failed.unreportedSessionMessage == nil)
        let expired = LimitsProviderSnapshot(
            provider: .claude,
            session: .init(percent: 50, resetsAt: Date().addingTimeInterval(-3600)), week: nil)
        #expect(expired.reportedSlots.isEmpty)
    }

    @Test @MainActor func unavailableClaudeDoesNotRestoreStaleHistoryAndSuccessRecovers()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-current-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic-history.jsonl")
        var history = LimitsHistory(url: url)
        history.append(
            provider: .claude, session: .init(percent: 23, resetsAt: nil),
            week: .init(percent: 41, resetsAt: nil), fable: .init(percent: 7, resetsAt: nil))
        let store = UsageStore(showMenuBar: false, historyURL: url)
        defer { store.shutdown() }
        await store.reloadLimitsFromHistory()
        #expect(store.session?.percent == 23)
        await store.receiveLimitsSnapshot(
            .init(
                refreshedAt: Date(),
                providers: [
                    .init(
                        provider: .claude, session: nil, week: nil, error: "Synthetic unavailable")
                ], failure: "Synthetic unavailable"))
        await store.reloadLimitsFromHistory()
        #expect(store.session == nil)
        #expect(store.week == nil)
        #expect(store.fableWeek == nil)
        await store.receiveLimitsSnapshot(
            .init(
                refreshedAt: Date(),
                providers: [
                    .init(
                        provider: .claude, session: .init(percent: 23, resetsAt: nil),
                        week: .init(percent: 41, resetsAt: nil),
                        fable: .init(percent: 7, resetsAt: nil))
                ], failure: nil))
        #expect(store.session?.percent == 23)
        #expect(store.fableWeek?.percent == 7)
        #expect(store.limitsError == nil)
    }

    @Test func cancelledClaudeRefreshDoesNotReadFallbackOrPersist() async {
        let task = Task {
            await LimitsCollector.fetchClaude(
                fetch: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .init(
                        provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
                },
                fallback: {
                    Issue.record("Cancelled refresh read fallback history")
                    return .init(provider: .claude, session: nil, week: nil)
                }, persist: { _ in Issue.record("Cancelled refresh persisted history") })
        }
        let result = await task.value
        #expect(result.0.session == nil)
        #expect(result.0.error == "Cancelled")
        #expect(result.1 == nil)
    }
}
