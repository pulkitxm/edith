import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostAgentJournalTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-journal-\(UUID().uuidString)")
    }

    @Test func writesArePrivateBoundedAndReplacementDirectoryIsRejected() throws {
        let root = directory()
        let moved = root.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: root);
            try? FileManager.default.removeItem(at: moved)
        }
        let journal = try HostAgentJournal(directory: root)
        let bytes = Data("private-fixture".utf8)
        try journal.write(bytes, name: "fixture.json", maximumBytes: 32)
        #expect(try journal.read("fixture.json", maximumBytes: 32) == bytes)
        let mode =
            try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent("fixture.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(throws: HostAgentCommandError.self) {
            try journal.write(Data(count: 33), name: "fixture.json", maximumBytes: 32)
        }
        #expect(throws: HostAgentCommandError.self) {
            try journal.read("fixture.json", maximumBytes: 2)
        }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(throws: HostAgentCommandError.self) {
            try journal.write(bytes, name: "fixture.json", maximumBytes: 32)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("fixture.json").path))
    }

    @Test func symlinksHardLinksPublicFilesAndTraversalFailClosed() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try HostAgentJournal(directory: root)
        try journal.write(Data("safe".utf8), name: "original.json", maximumBytes: 32)
        let original = root.appendingPathComponent("original.json")
        let alias = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        for action in [0, 1, 2] {
            #expect(throws: HostAgentCommandError.self) {
                if action == 0 {
                    _ = try journal.read("alias.json", maximumBytes: 32)
                } else if action == 1 {
                    try journal.write(Data(), name: "alias.json", maximumBytes: 32)
                } else {
                    try journal.remove("alias.json")
                }
            }
        }
        #expect(link(original.path, root.appendingPathComponent("hard.json").path) == 0)
        #expect(throws: HostAgentCommandError.self) {
            try journal.read("hard.json", maximumBytes: 32)
        }
        #expect(throws: HostAgentCommandError.self) {
            try journal.read("original.json", maximumBytes: 32)
        }
        #expect(throws: HostAgentCommandError.self) {
            try journal.read("../original.json", maximumBytes: 32)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("hard.json"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: original.path)
        #expect(throws: HostAgentCommandError.self) {
            try journal.read("original.json", maximumBytes: 32)
        }
    }

    @Test func taskRecoveryRequiresMatchingUUIDFilenameAndPrivateRecord() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try HostAgentTaskService(directory: root)
        await service.register(operation: "fixture") { payload, _ in payload }
        let request = HostAgentTaskSubmission(
            operation: "fixture", title: "Fixture", payload: Data("result".utf8))
        _ = try await service.submit(request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await !service.status(request.id).snapshot.state.isTerminal,
            ContinuousClock.now < deadline
        { await Task.yield() }
        try #require(try await service.status(request.id).snapshot.state == .succeeded)
        await service.shutdown()
        let journal = try HostAgentJournal(directory: root)
        let original = "\(request.id.uuidString).json"
        let bytes = try journal.read(original, maximumBytes: 1 << 20)
        try journal.write(bytes, name: "\(UUID().uuidString).json", maximumBytes: 1 << 20)
        try journal.remove(original)
        let restored = try HostAgentTaskService(directory: root)
        #expect(await restored.snapshots().isEmpty)
        await restored.shutdown()
    }
}
