import Foundation
import Testing

@testable import UsageExtension

private actor AccountWorkerProbe {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    func entered() -> Int {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        return calls
    }
    func left() { active -= 1 }
}

@MainActor @Suite struct UsageAccountWorkerInvalidationTests {
    @Test func accountChangesJoinThePreviousCollectionBeforePublishingFreshQuotas() async throws {
        let probe = AccountWorkerProbe()
        let controller = UsageWorkerController(
            dataDirectory: URL(fileURLWithPath: "/synthetic/usage"),
            fetchLimits: { _ in
                let invocation = await probe.entered()
                if invocation == 1 {
                    do { try await Task.sleep(for: .seconds(60)) } catch {
                        await probe.left()
                        return .init(refreshedAt: Date(), providers: [], failure: "Cancelled")
                    }
                }
                await probe.left()
                return .init(
                    refreshedAt: Date(), providers: [], failure: nil,
                    claudeAccounts: [
                        .init(
                            id: UUID(), name: "Fresh synthetic account",
                            limits: .init(
                                provider: .claude,
                                session: .init(percent: 42, resetsAt: nil), week: nil),
                            refreshedAt: Date())
                    ])
            }, allowsBackgroundCollection: { false }
        ) { _, _ in
            Issue.record("Account change started usage collection"); return Data()
        }
        try controller.requestLimitsRefresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await probe.active != 1 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await controller.accountsChanged()
        try await controller.waitForLimitsRefresh()
        #expect(await probe.calls == 2)
        #expect(await probe.maximumActive == 1)
        #expect(controller.latestLimits?.claudeAccounts.first?.limits.session?.percent == 42)
        await controller.shutdown()
        #expect(await probe.active == 0)
    }
}
