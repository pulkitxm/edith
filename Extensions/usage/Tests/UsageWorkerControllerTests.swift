import Foundation
import Testing
@testable import UsageExtension

@MainActor @Suite(.serialized)
struct UsageWorkerControllerTests {
    @Test func cancelledWaiterDetachesAndStaleRunCannotCancelCurrentCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return try emptyDocument()
        }
        let first = try controller.requestRefresh()
        await controller.cancelRefresh(matching: first)
        let second = try controller.requestRefresh()
        try #require(first != second)
        let waiter = Task { await controller.waitForRefresh() }
        try await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        await waiter.value
        #expect(controller.refreshing)
        await controller.cancelRefresh(matching: first)
        #expect(controller.refreshing)
        await controller.cancelRefresh(matching: second)
        #expect(!controller.refreshing)
        await controller.shutdown()
    }

    @Test func refreshCoalescesPublishesValidatedHistoryAndReportsIncompletePricing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try emptyDocument(pricing: ["unpricedModels": ["sample-unpriced"]])
        let controller = UsageWorkerController(dataDirectory: root) { _, progress in
            progress(.note("Collecting fixture usage"))
            try await Task.sleep(for: .milliseconds(20))
            return data
        }
        let first = try controller.requestRefresh()
        #expect(try controller.requestRefresh() == first)
        await controller.waitForRefresh()
        #expect(!controller.refreshing)
        #expect(controller.failure == nil)
        #expect(controller.notice?.contains("1 unpriced model") == true)
        #expect(
            UsageHistory.isValidDocument(
                try Data(contentsOf: root.appendingPathComponent("usage.json"))))
        #expect(
            try String(contentsOf: root.appendingPathComponent("refresh.log"), encoding: .utf8)
                .contains("Collecting fixture usage"))
        await controller.shutdown()
    }

    @Test func shutdownCancelsCollectionAndRejectsFurtherWorkWithoutPublishing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return try emptyDocument()
        }
        _ = try controller.requestRefresh()
        await controller.shutdown()
        #expect(!controller.refreshing)
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("usage.json").path))
        #expect(throws: (any Error).self) { try controller.requestRefresh() }
    }

    @Test func suspendingReturnsWhileACollectionIgnoresCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = UsageBlockedCollection()
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            await release.wait()
            return try emptyDocument()
        }
        _ = try controller.requestRefresh()
        try await Task.sleep(for: .milliseconds(50))
        let finished = UsageBlockedCollection()
        Task {
            await controller.suspendAndWait()
            await finished.open()
        }
        let outcome = await finished.wait(within: .seconds(10))
        await release.open()
        #expect(outcome)
        await controller.shutdown()
    }

    @Test func malformedCollectionPreservesExistingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try emptyDocument()
        let url = root.appendingPathComponent("usage.json")
        try previous.write(to: url)
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in Data("invalid".utf8) }
        _ = try controller.requestRefresh()
        await controller.waitForRefresh()
        #expect(controller.failure != nil)
        #expect(try Data(contentsOf: url) == previous)
        await controller.shutdown()
    }

    @Test func fixtureHomeOverridesExternalConfigurationAndInvalidPathsAreRejected() {
        let home = "/tmp/sample-home"
        #expect(
            UsageExecutionEnvironment.collectorEnvironment([
                "EDITH_EXTENSION_FIXTURE_HOME": home, "CLAUDE_CONFIG_DIR": "/tmp/other",
                "TZ": "UTC",
            ]) == ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"])
        #expect(
            UsageExecutionEnvironment.fixtureHome(environment: [
                "EDITH_EXTENSION_FIXTURE_HOME": "relative"
            ]) == nil)
        #expect(
            ClaudeStatusLine.settingsURL(environment: [
                "EDITH_EXTENSION_FIXTURE_HOME": home, "CLAUDE_CONFIG_DIR": "/tmp/other",
            ]).path == home + "/.claude/settings.json")
    }
}

private func emptyDocument(pricing: [String: Any] = [:]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 8, "generatedAt": "2026-10-09T12:00:00Z", "sources": [],
        "defaultSources": [],
        "sourceMeta": [:], "sessions": [], "daily": [], "pricing": pricing,
        "totals": [
            "cost": 0, "tokens": 0, "inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0,
            "cacheReadTokens": 0, "bySource": [:],
        ],
    ])
}

@MainActor @Suite(.serialized)
struct UsageBackgroundShutdownTests {
    @Test func shuttingDownWhileTheBackgroundLoopSleepsDoesNotAbort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UsageWorkerController(
            dataDirectory: root,
            fetchLimits: { _ in .init(refreshedAt: Date(), providers: [], failure: nil) },
            projectLimits: { _ in .init(refreshedAt: Date(), providers: [], failure: nil) },
            allowsBackgroundCollection: { true }
        ) { _, _ in try emptyDocument() }
        controller.startBackgroundCollection()
        try await Task.sleep(for: .milliseconds(300))
        await controller.shutdown()
    }

    @Test func mainQueueWakeFiresAfterItsDelayAndCancelledWakesNeverFire() async throws {
        var fired: [String] = []
        let cancel = UsageWake.mainQueue(after: .milliseconds(50)) { fired.append("cancelled") }
        _ = UsageWake.mainQueue(after: .milliseconds(50)) { fired.append("kept") }
        cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while fired.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fired == ["kept"])
    }
}

actor UsageBlockedCollection {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func wait(within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while !opened, clock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        return opened
    }
}
