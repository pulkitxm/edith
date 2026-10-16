import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

private actor SelectionProjectionFixture {
    let originalTime = Date(timeIntervalSince1970: 1_000)
    let deadline = Date(timeIntervalSince1970: 1_120)
    private var now = Date(timeIntervalSince1970: 1_000)
    private var seeded = false
    private var session: LimitsRefreshSession?
    private(set) var fetched: [LimitProvider] = []

    func advanceToExpiry() { now = deadline }

    func fetch(_ session: LimitsRefreshSession, force: Bool) async -> LimitsTopicSnapshot {
        self.session = session
        if !seeded {
            seeded = true
            if case .collect(let lease) = await session.begin(
                force: false, providers: [.codex, .cursor], now: originalTime)
            {
                let paused = LimitsTopicSnapshot(
                    refreshedAt: originalTime,
                    providers: [LimitProvider.codex, .cursor].map {
                        .init(
                            provider: $0, session: .init(percent: 73, resetsAt: deadline),
                            week: nil, error: "Synthetic rate limit")
                    }, failure: "Synthetic rate limit")
                _ = await session.finish(
                    paused, retryNotBefore: [.codex: deadline, .cursor: deadline], lease: lease.id)
            }
        }
        return await LimitsCollector.collect(
            providers: [.codex, .cursor], force: force, refreshSession: session, now: now,
            announce: { _ in },
            fetch: { provider in
                self.recordFetch(provider)
            })
    }

    func retryDeadline(_ provider: LimitProvider) async -> Date? {
        await session?.retryDeadline(for: provider)
    }

    private func recordFetch(_ provider: LimitProvider) -> (LimitsProviderSnapshot, Date?) {
        fetched.append(provider)
        return (
            .init(provider: provider, session: .init(percent: 19, resetsAt: nil), week: nil), nil
        )
    }
}

@MainActor @Suite struct UsageSelectionProjectionTests {
    @Test func selectionProjectionRetainsProviderDeadlinesAndFetchesOnceAtExpiry() async throws {
        let fixture = SelectionProjectionFixture()
        let controller = makeController(fixture)
        let commands = UsageReportCommands(
            controller: controller,
            store: .init(url: URL(fileURLWithPath: "/synthetic/usage/usage.json")),
            directory: URL(fileURLWithPath: "/synthetic/usage"))
        do {
            for _ in 0..<2 {
                _ = try await commands.execute("usage.limits.project", payload: Data("{}".utf8))
                try await controller.waitForLimitsRefresh()
                #expect(await fixture.fetched.isEmpty)
                #expect(controller.latestLimits?.refreshedAt == fixture.originalTime)
                #expect(controller.latestLimits?.providers.map { $0.session?.percent } == [73, 73])
                #expect(await fixture.retryDeadline(.codex) == fixture.deadline)
                #expect(await fixture.retryDeadline(.cursor) == fixture.deadline)
            }
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await commands.execute(
                    "usage.limits.project", payload: Data(#"{"force":true}"#.utf8))
            }
            await fixture.advanceToExpiry()
            _ = try await commands.execute("usage.limits.project", payload: Data("{}".utf8))
            try await controller.waitForLimitsRefresh()
            #expect(await fixture.fetched == [.codex, .cursor])
            #expect(controller.latestLimits?.providers.map { $0.session?.percent } == [19, 19])
        } catch {
            await commands.shutdown()
            await controller.shutdown()
            throw error
        }
        await commands.shutdown()
        await controller.shutdown()
    }

    @Test func explicitManualRefreshStillOverridesProviderRetryDeadlines() async throws {
        let fixture = SelectionProjectionFixture()
        let controller = makeController(fixture)
        let commands = UsageReportCommands(
            controller: controller,
            store: .init(url: URL(fileURLWithPath: "/synthetic/usage/usage.json")),
            directory: URL(fileURLWithPath: "/synthetic/usage"))
        do {
            _ = try await commands.execute("usage.limits.project", payload: Data("{}".utf8))
            try await controller.waitForLimitsRefresh()
            #expect(await fixture.fetched.isEmpty)
            _ = try await commands.execute("usage.limits.refresh", payload: Data("{}".utf8))
            try await controller.waitForLimitsRefresh()
            #expect(await fixture.fetched == [.codex, .cursor])
            #expect(await fixture.retryDeadline(.codex) == nil)
            #expect(await fixture.retryDeadline(.cursor) == nil)
        } catch {
            await commands.shutdown()
            await controller.shutdown()
            throw error
        }
        await commands.shutdown()
        await controller.shutdown()
    }

    private func makeController(_ fixture: SelectionProjectionFixture) -> UsageWorkerController {
        UsageWorkerController(
            dataDirectory: URL(fileURLWithPath: "/synthetic/usage"),
            fetchLimits: { await fixture.fetch($0, force: true) },
            projectLimits: { await fixture.fetch($0, force: false) },
            allowsBackgroundCollection: { false }
        ) { _, _ in
            Issue.record("Selection projection started usage collection")
            return Data()
        }
    }
}
