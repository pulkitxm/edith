import Foundation
import GhosttyTerminal
@testable import Edith
@testable import EdithKit
import Testing

@Suite struct TerminalDropTransferTests {
    @Test func remoteDropPathsAreTemporaryUniqueAndShellSafe() {
        let url = URL(fileURLWithPath: "/Users/me/Desktop/my image (final).png")
        let path = TerminalDropTransfer.remotePath(
            for: url, directory: "/tmp", identifier: "1234")

        #expect(path == "/tmp/edith-drop-1234-my_image__final_.png")
        #expect(ShellQuote.quote(path) == path)
    }

    @Test func remoteDropPathsUseTheWindowsTemporaryDirectory() {
        let url = URL(fileURLWithPath: "/Users/me/Desktop/my image.png")
        let path = TerminalDropTransfer.remotePath(
            for: url, directory: "C:\\Users\\me\\AppData\\Local\\Temp\\",
            identifier: "5678")

        #expect(path == "C:\\Users\\me\\AppData\\Local\\Temp\\edith-drop-5678-my_image.png")
    }
}

@MainActor
@Suite struct TerminalRemoteDropDeliveryTests {
    private struct UploadFailure: LocalizedError {
        var errorDescription: String? { "The machine refused the upload." }
    }

    private func holder(typing delivered: @escaping (String) -> Void) throws
        -> TerminalSessionHolder
    {
        let holder = TerminalSessionHolder(deliverGhosttyInput: { _, text in
            delivered(text)
            return true
        })
        holder.start(executable: "/bin/cat", arguments: [], environment: [])
        let launch = try #require(holder.ghosttyLaunch)
        _ = holder.retainedGhosttyView(
            launch: launch, theme: GhosttyTheme(palette: .edith(dark: true)))
        return holder
    }

    private func temporaryImage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-remote-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("drop.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        return file
    }

    @Test func uploadedPathsAreTypedAndTheLocalCopyIsRemoved() async throws {
        var typed: [String] = []
        let holder = try holder { typed.append($0) }
        defer { holder.stop() }
        let image = try temporaryImage()
        var uploaded: [URL] = []

        await holder.deliverRemoteDrop(
            TerminalDropPayload(files: [image], temporaryFiles: [image])
        ) { files in
            uploaded = files
            return ["/tmp/edith-drop-1-drop.png", "/tmp/my shot.png"]
        }

        #expect(uploaded == [image])
        #expect(typed == ["/tmp/edith-drop-1-drop.png '/tmp/my shot.png'"])
        #expect(!FileManager.default.fileExists(atPath: image.path))
        #expect(!holder.transferringDrop)
        #expect(holder.dropTransferError == nil)
    }

    @Test func aFailedUploadIsShownAndTypesNothing() async throws {
        var typed: [String] = []
        let holder = try holder { typed.append($0) }
        defer { holder.stop() }
        let image = try temporaryImage()

        await holder.deliverRemoteDrop(
            TerminalDropPayload(files: [image], temporaryFiles: [image])
        ) { _ in throw UploadFailure() }

        #expect(typed.isEmpty)
        #expect(holder.dropTransferError == "The machine refused the upload.")
        #expect(!holder.transferringDrop)
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }
}
