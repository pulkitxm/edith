import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct StorageInspectionTests {
    @Test func backupEntriesAreMeasuredWithoutFollowingLinksAcrossXPCAndRefresh() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        let records = cloud.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let settings = cloud.appendingPathComponent("settings.json")
        try Data(repeating: 1, count: 64).write(to: settings)
        try Data(repeating: 1, count: 128).write(to: records.appendingPathComponent("a.json"))
        try Data(repeating: 1, count: 16).write(to: records.appendingPathComponent(".hidden"))
        try Data(repeating: 1, count: 8).write(to: cloud.appendingPathComponent(".hidden"))
        let external = root.appendingPathComponent("external")
        try Data(repeating: 1, count: 4_096).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: records.appendingPathComponent("link"), withDestinationURL: external)
        let workflow = StorageInspectionWorkflow(cloudDirectory: cloud)
        let runtime = AgentRuntime(build: "storage-fixture", store: nil)
        let tasks = try AgentTaskService(directory: nil)
        await workflow.register(on: tasks)
        await AgentTaskOperations.register(on: runtime, service: tasks)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = StorageInspectionClient(client: listener.client())
        let first = try await client.inspect()
        #expect(first.restoreEntries.map(\.name) == ["records", "settings.json"])
        #expect(first.restoreEntries.first?.bytes == 144)
        #expect(first.restoreEntries.last?.bytes == 64)
        try Data(repeating: 1, count: 256).write(to: settings)
        #expect(try await client.inspect().restoreEntries.last?.bytes == 64)
        #expect(try await client.inspect(force: true).restoreEntries.last?.bytes == 256)
        #expect(await tasks.snapshots().allSatisfy { $0.state == .succeeded })
        await runtime.shutdown()
    }

    @Test func aMissingBackupDirectoryHasNoEntriesOrIssues() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workflow = StorageInspectionWorkflow(
            cloudDirectory: root.appendingPathComponent("missing"))
        let snapshot = try await workflow.inspect()
        #expect(snapshot.restoreEntries.isEmpty)
        #expect(snapshot.issues.isEmpty)
    }

    @Test func traversalAndBackupListingLimitsReportPartialSizes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        for index in 0..<300 { try Data([1]).write(to: cloud.appendingPathComponent("\(index)")) }
        let workflow = StorageInspectionWorkflow(cloudDirectory: cloud, maximumEntries: 2)
        let snapshot = try await workflow.inspect()
        #expect(snapshot.restoreEntries.count == 256)
        #expect(snapshot.issues.contains { $0.contains("sizes are partial") })
        #expect(snapshot.issues.contains { $0.contains("256") })
    }

    @Test func cancellationStopsTheOwnedInspectionWorkerAndAllowsAnotherRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("fixture"))
        let workflow = StorageInspectionWorkflow(cloudDirectory: root)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let pending = Task {
            try await workflow.inspect { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        let enteredResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 3))
            }
        }
        #expect(enteredResult == .success)
        pending.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let replacement = try await workflow.inspect()
        #expect(replacement.restoreEntries == [.init(name: "fixture", bytes: 1)])
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "storage-inspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
