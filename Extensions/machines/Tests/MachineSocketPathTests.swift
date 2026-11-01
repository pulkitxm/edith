@testable import MachinesExtension
import Darwin
import Foundation
import Testing

@Suite @MainActor struct MachineSocketPathTests {
    @Test func longMachineDataPathsUseDistinctPrivateBoundedSocketDirectories() throws {
        let original = MachinePaths.root
        defer { MachinePaths.root = original }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(String(repeating: "long-directory-", count: 12))
        MachinePaths.root = root
        let directory = MachinePaths.socketsDir
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = MachinePaths.socketFile(for: UUID(), connectionID: UUID())
        #expect(socket.path.utf8.count < 104)
        #expect(
            directory != MachinePaths.socketDirectory(for: root.appendingPathComponent("other")))
        try MachinePaths.prepareSockets()
        var metadata = stat()
        #expect(lstat(directory.path, &metadata) == 0)
        #expect(metadata.st_uid == getuid())
        #expect(metadata.st_mode & 0o777 == 0o700)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(throws: CocoaError.self) { try MachinePaths.prepareSockets() }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
        #expect(throws: CocoaError.self) { try MachinePaths.prepareSockets() }
    }

    @Test func shortMachineDataPathsKeepTheirOwnedSocketDirectory() {
        let root = URL(fileURLWithPath: "/tmp/synthetic-machines")
        #expect(MachinePaths.socketDirectory(for: root) == root.appendingPathComponent("sockets"))
    }
}
