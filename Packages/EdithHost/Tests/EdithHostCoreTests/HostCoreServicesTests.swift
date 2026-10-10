import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCoreStorageTests {
    @Test func inspectionMeasuresActualFilesWithoutFollowingLinks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data")
        let nested = data.appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 23).write(to: data.appendingPathComponent("one"))
        try Data(repeating: 2, count: 42).write(to: nested.appendingPathComponent("two"))
        let foreign = root.appendingPathComponent("foreign")
        try Data(repeating: 3, count: 97).write(to: foreign)
        try FileManager.default.createSymbolicLink(
            at: data.appendingPathComponent("link"), withDestinationURL: foreign)
        let result = try HostStorageInspection.inspect(
            targets: [
                HostStorageTarget(id: "data", title: "Data", url: data),
                HostStorageTarget(id: "usage", title: "Usage", url: nested),
                HostStorageTarget(
                    id: "link", title: "Link", url: data.appendingPathComponent("link")),
            ], cloud: root.appendingPathComponent("cloud"))
        #expect(result.footprints.map(\.bytes) == [65, 42, 0])
        #expect(result.issues.isEmpty)
    }

    @Test func boundedInspectionReportsPartialMeasurementsAndCancellation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c"] {
            try Data(repeating: 1, count: 9).write(to: root.appendingPathComponent(name))
        }
        let targets = [HostStorageTarget(id: "files", title: "Files", url: root)]
        let result = try HostStorageInspection.inspect(
            targets: targets, cloud: root.appendingPathComponent("cloud"), maximumEntries: 1)
        #expect(result.footprints[0].bytes == 9)
        #expect(result.issues.count == 1)
        #expect(throws: CancellationError.self) {
            try HostStorageInspection.inspect(targets: targets, cloud: root, isCancelled: { true })
        }
    }

    @Test func privateAtomicWritesReplaceLinksWithoutTouchingTheirTargets() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign")
        try Data("foreign".utf8).write(to: foreign)
        let destination = root.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: foreign)
        try HostCoreFiles.write(Data("owned".utf8), to: destination)
        #expect(try String(contentsOf: foreign, encoding: .utf8) == "foreign")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "owned")
        var metadata = stat()
        #expect(lstat(destination.path, &metadata) == 0)
        #expect(metadata.st_mode & S_IFMT == S_IFREG)
        #expect(metadata.st_mode & 0o777 == 0o600)
    }

    @Test func cloudNamespacesDoNotReachProductionFromDevelopment() throws {
        let home = URL(fileURLWithPath: "/synthetic/home")
        let support = URL(fileURLWithPath: "/synthetic/support")
        let production = try HostIdentity(identifier: "com.pulkit.edith", supportDirectory: support)
        let development = try HostIdentity(
            identifier: "com.pulkit.edith.dev.synthetic", supportDirectory: support)
        #expect(
            HostCoreCloud.directory(identity: production, home: home).path
                == "/synthetic/home/Library/Mobile Documents/com~apple~CloudDocs/Edith")
        #expect(
            HostCoreCloud.directory(identity: development, home: home)
                == development.root.appendingPathComponent("iCloud"))
    }
}

@Suite @MainActor struct HostCoreRuntimeTests {
    @Test func realInspectionPersistsTasksAndReopensTheJournal() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.core-" + UUID().uuidString,
            supportDirectory: directory)
        let runtime = try HostCoreRuntime(identity: identity)
        try FileManager.default.createDirectory(
            at: identity.extensionDirectory("usage"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 39).write(
            to: identity.extensionDirectory("usage").appendingPathComponent("synthetic"))
        let measured = try await runtime.inspect()
        #expect(measured.pid == getpid())
        #expect(measured.residentBytes > 0)
        #expect(measured.storage?.footprints.first(where: { $0.id == "usage" })?.bytes == 39)
        #expect(measured.tasks.last?.phase == .completed)
        await runtime.shutdown()
        let restored = try HostCoreRuntime(identity: identity)
        #expect(restored.snapshot().tasks.last?.id == measured.tasks.last?.id)
        #expect(restored.snapshot().tasks.last?.phase == .completed)
        await restored.shutdown()
    }

    @Test func interruptedTasksBecomeCancelledAndForeignJournalIsRejected() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.core-" + UUID().uuidString,
            supportDirectory: directory)
        let runtime = try HostCoreRuntime(identity: identity)
        await runtime.shutdown()
        let journal = identity.root.appendingPathComponent("Core/tasks.json")
        let running = HostCoreTaskSnapshot(
            id: UUID(), title: "Synthetic operation", startedAt: Date(), finishedAt: nil,
            phase: .running, message: nil)
        try HostCoreFiles.write(JSONEncoder().encode([running]), to: journal)
        let restarted = try HostCoreRuntime(identity: identity)
        #expect(restarted.snapshot().tasks.last?.phase == .cancelled)
        #expect(restarted.snapshot().tasks.last?.finishedAt != nil)
        await restarted.shutdown()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: journal.path)
        #expect(throws: CocoaError.self) { try HostCoreRuntime(identity: identity) }
    }
}

private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "core-synthetic-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}
