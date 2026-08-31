import Foundation
import Testing

@testable import EdithKit

@Suite struct SSHUploadLiveTests {
    @Test func uploadsAndDownloadsBinaryDataThroughANewTemporaryDirectory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let target = environment["EDITH_SSH_UPLOAD_LIVE_TARGET"] else { return }
        let machine = Machine(
            name: target, host: target, source: .sshConfigAlias(target))
        let connection = SSHConnection(machine: machine)
        try await connection.connect()
        let platform = try #require(await connection.remotePlatform)
        let temporaryDirectory = try await connection.temporaryDirectory()
        let testDirectory = FileListing.join(
            parent: temporaryDirectory, name: "edith-upload-live-\(UUID().uuidString)")
        let remote = FileListing.join(
            parent: FileListing.join(parent: testDirectory, name: "nested"),
            name: "payload.bin")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-upload-source-\(UUID().uuidString).bin")
        let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-upload-result-\(UUID().uuidString).bin")
        let data = Data((0..<(512 * 1024)).map { UInt8($0 % 251) })
        try data.write(to: local)

        do {
            try await connection.upload(localURL: local, toRemotePath: remote)
            try await connection.download(remotePath: remote, to: downloaded)
            #expect(try Data(contentsOf: downloaded) == data)
            try await remove(testDirectory, platform: platform, connection: connection)
        } catch {
            try? await remove(testDirectory, platform: platform, connection: connection)
            throw error
        }

        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.removeItem(at: downloaded)
        await connection.disconnect()
    }

    private func remove(
        _ path: String, platform: RemoteMachinePlatform, connection: SSHConnection
    ) async throws {
        let command =
            platform == .windows
            ? PowerShell.userCommand(
                "Remove-Item -LiteralPath \(PowerShell.literal(path)) -Recurse -Force")
            : "rm -rf -- \(ShellQuote.quote(path))"
        try await connection.runChecked(command)
    }
}
