import Foundation
import Testing

@testable import EdithDatabase
@testable import EdithDatabaseDrivers

@Suite
struct DatabaseBrokerServiceRepairerTests {
    @Test func repairPreparesAndLaunchesBeforeWaitingForReadiness() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "eddb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = RepairCallRecorder()
        let repairer = DatabaseBrokerServiceRepairer(
            paths: DatabaseBrokerPaths(
                dataDirectory: root.appendingPathComponent("data"),
                runtimeDirectory: root.appendingPathComponent("runtime")),
            preparePack: { await calls.record("pack") },
            launch: { await calls.record("launch") },
            ensureReady: { await calls.record("ready") })
        try await repairer.repair()
        #expect(await calls.steps == ["pack", "launch", "ready"])
    }

    @Test func failedLaunchDoesNotClaimReadinessAndCanBeRetried() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "eddb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = RepairCallRecorder()
        let repairer = DatabaseBrokerServiceRepairer(
            paths: DatabaseBrokerPaths(
                dataDirectory: root.appendingPathComponent("data"),
                runtimeDirectory: root.appendingPathComponent("runtime")),
            preparePack: { await calls.record("pack") },
            launch: {
                await calls.record("launch")
                if await calls.launchAttempts == 1 { throw DatabaseBrokerRepairError.launchFailed }
            },
            ensureReady: { await calls.record("ready") })
        await #expect(throws: DatabaseBrokerRepairError.launchFailed) {
            try await repairer.repair()
        }
        #expect(await calls.steps == ["pack", "launch"])
        try await repairer.repair()
        #expect(await calls.steps == ["pack", "launch", "pack", "launch", "ready"])
    }

    @Test func anAbsentServiceNeedsNoManualCleanup() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "eddb-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DatabaseBrokerPaths(
            dataDirectory: root.appendingPathComponent("data", isDirectory: true),
            runtimeDirectory: root.appendingPathComponent("runtime", isDirectory: true))
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectory,
            withIntermediateDirectories: true)

        try await DatabaseBrokerServiceRepairer(paths: paths).repair()
    }
}

private actor RepairCallRecorder {
    private(set) var steps: [String] = []
    var launchAttempts: Int { steps.filter { $0 == "launch" }.count }

    func record(_ step: String) {
        steps.append(step)
    }
}
