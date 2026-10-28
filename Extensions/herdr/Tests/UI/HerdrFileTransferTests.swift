import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import HerdrUI

@Suite struct HerdrFileTransferTests {
    private func request(_ script: String, timeout: TimeInterval = 5) -> CLICommandRequest {
        CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"], timeout: timeout, terminatesProcessGroup: true)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func downloadsPreserveBinaryBytesAndReplaceOnlyAfterSuccess() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.bin")
        try Data("previous".utf8).write(to: destination)
        let expected = Data((0..<256).map(UInt8.init))
        try await HerdrFileTransfer.download(
            request: request("import sys; sys.stdout.buffer.write(bytes(range(256)))"),
            to: destination, maximumBytes: 256)
        #expect(try Data(contentsOf: destination) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["download.bin"])
    }

    @Test func oversizedAndFailedDownloadsPreserveThePreviousFileAndRemoveStaging() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.bin")
        let original = Data("previous".utf8)
        try original.write(to: destination)
        for script in [
            "import sys; sys.stdout.buffer.write(b'x'*257)",
            "import sys; sys.stdout.buffer.write(b'x'); sys.stderr.write('synthetic failure'); sys.exit(1)",
        ] {
            await #expect(throws: (any Error).self) {
                try await HerdrFileTransfer.download(
                    request: request(script), to: destination, maximumBytes: 256)
            }
            #expect(try Data(contentsOf: destination) == original)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: root.path) == ["download.bin"])
        }
    }

    @Test func noisyErrorOutputDoesNotBlockTheTransfer() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.bin")
        let clock = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await HerdrFileTransfer.download(
                request: request("import sys; sys.stderr.write('x'*2000000); sys.exit(1)"),
                to: destination, maximumBytes: 256)
        }
        #expect(clock.duration(to: .now) < .seconds(5))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func uploadsStreamAllBinaryBytesToTheChild() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("upload.bin")
        try Data((0..<256).map(UInt8.init)).write(to: source)
        try await HerdrFileTransfer.upload(
            request: request(
                "import sys; data=sys.stdin.buffer.read(); sys.exit(0 if data==bytes(range(256)) else 1)"
            ), from: source)
    }

    @Test func timeoutAndCancellationReapTheTransferAndRemoveItsPartialDownload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.bin")
        let pidFile = root.appendingPathComponent("pid")
        let script =
            "import os,sys,time; open(sys.argv[1]+'.t','w').write(str(os.getpid())); os.rename(sys.argv[1]+'.t',sys.argv[1]); time.sleep(60)"
        for cancel in [false, true] {
            let request = CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script, pidFile.path], environment: ["PATH": "/usr/bin:/bin"],
                timeout: cancel ? 30 : 5, terminatesProcessGroup: true)
            let task = Task {
                try await HerdrFileTransfer.download(
                    request: request, to: destination, maximumBytes: 256)
            }
            let deadline = ContinuousClock.now + .seconds(4)
            while !FileManager.default.fileExists(atPath: pidFile.path),
                ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(10))
            }
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
            if cancel { task.cancel() }
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            try FileManager.default.removeItem(at: pidFile)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func windowsTransfersUseBinaryStreamsAndQuoteLiteralPaths() throws {
        let path = "C:\\Synthetic Files\\it's [data].bin"
        let download = try SSHConnection.downloadCommand(
            path: path, platform: .windows, maximumBytes: 256)
        let upload = try SSHConnection.uploadCommand(path: path, platform: .windows)
        for command in [download, upload] {
            let encoded = try #require(command.components(separatedBy: "-EncodedCommand ").last)
            let data = try #require(Data(base64Encoded: encoded))
            let script = try #require(String(data: data, encoding: .utf16LittleEndian))
            #expect(
                script.replacingOccurrences(of: "''", with: "'")
                    .contains("'C:\\Synthetic Files\\it''s [data].bin'"))
            #expect(script.contains("finally"))
            #expect(script.contains("OpenStandard"))
        }
        #expect(throws: (any Error).self) {
            try SSHConnection.downloadCommand(path: path, platform: .windows, maximumBytes: -1)
        }
    }
}
