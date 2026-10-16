import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageCurrentLimitsTests {
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
