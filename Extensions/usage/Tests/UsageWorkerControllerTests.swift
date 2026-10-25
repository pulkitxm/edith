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
