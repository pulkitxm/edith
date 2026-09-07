import Darwin
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct StorageInspectionTests {
    @Test func theDataTotalIncludesDatabaseJournalsAndTaskHistoryInOneTraversal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks = root.appendingPathComponent("Tasks")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("edith.sqlite"))
        try Data(repeating: 1, count: 8192).write(
            to: root.appendingPathComponent("edith.sqlite-wal"))
        try Data(repeating: 1, count: 128).write(to: tasks.appendingPathComponent("task.json"))
        let workflow = StorageInspectionWorkflow(
            targets: [
                .init(id: "data", title: "Data", url: root),
                .init(id: "tasks", title: "Tasks", url: tasks),
            ],
            cloudDirectory: root.appendingPathComponent("missing"), maximumEntries: 4)
        let result = try await workflow.inspect()
        #expect(result.footprints.first?.bytes == 12_416)
        #expect(result.footprints.last?.bytes == 128)
        #expect(result.issues.isEmpty)
    }

    @Test func inspectionCrossesXPCAndExplicitRefreshReplacesCachedSizes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let file = data.appendingPathComponent("record.json")
        try Data(repeating: 1, count: 128).write(to: file)
        try Data(repeating: 1, count: 16).write(to: data.appendingPathComponent(".hidden"))
        let external = root.appendingPathComponent("external")
        try Data(repeating: 1, count: 4_096).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: data.appendingPathComponent("link"), withDestinationURL: external)
        #expect(mkfifo(data.appendingPathComponent("fifo").path, 0o600) == 0)
        try Data(repeating: 1, count: 64).write(to: cloud.appendingPathComponent("settings.json"))
        let workflow = StorageInspectionWorkflow(
            targets: [.init(id: "fixture", title: "Fixture", url: data)], cloudDirectory: cloud)
        let runtime = AgentRuntime(build: "storage-fixture", store: nil)
        let tasks = try AgentTaskService(directory: nil)
        await workflow.register(on: tasks)
        await AgentTaskOperations.register(on: runtime, service: tasks)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = StorageInspectionClient(client: listener.client())
        let first = try await client.inspect()
        #expect(first.footprints.first?.bytes == 144)
        #expect(first.restoreEntries == [.init(name: "settings.json", bytes: 64)])
        #expect(first.issues.isEmpty)
        try Data(repeating: 1, count: 256).write(to: file)
        #expect(try await client.inspect().footprints.first?.bytes == 144)
        #expect(try await client.inspect(force: true).footprints.first?.bytes == 272)
        #expect(await tasks.snapshots().allSatisfy { $0.state == .succeeded })
        await runtime.shutdown()
    }

    @Test func traversalAndBackupListingLimitsReportPartialSizes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data", isDirectory: true)
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        for index in 0..<5 { try Data([1]).write(to: data.appendingPathComponent("\(index)")) }
        for index in 0..<300 { try Data([1]).write(to: cloud.appendingPathComponent("\(index)")) }
        let workflow = StorageInspectionWorkflow(
            targets: [.init(id: "fixture", title: "Fixture", url: data)],
            cloudDirectory: cloud, maximumEntries: 2)
        let snapshot = try await workflow.inspect()
        #expect(snapshot.footprints.first?.bytes == 2)
        #expect(snapshot.restoreEntries.count == 256)
        #expect(snapshot.issues.contains { $0.contains("sizes are partial") })
        #expect(snapshot.issues.contains { $0.contains("256") })
    }

    @Test func cancellationStopsTheOwnedInspectionWorkerAndAllowsAnotherRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("fixture"))
        let workflow = StorageInspectionWorkflow(
            targets: [.init(id: "fixture", title: "Fixture", url: root)],
            cloudDirectory: root.appendingPathComponent("missing"))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let pending = Task {
            try await workflow.inspect { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        #expect(entered.wait(timeout: .now() + 3) == .success)
        pending.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let replacement = try await workflow.inspect()
        #expect(replacement.footprints.first?.bytes == 1)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "storage-inspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
