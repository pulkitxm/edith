import Foundation
import Testing

@testable import EdithKit

@Suite struct SSHClipboardLiveTests {
    @Test func syncsBidirectionallyWhenALiveTargetIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let target = environment["EDITH_SSH_CLIPBOARD_LIVE_TARGET"] else { return }
        let name = environment["EDITH_SSH_CLIPBOARD_LIVE_NAME"] ?? target
        let display = environment["EDITH_SSH_CLIPBOARD_LIVE_DISPLAY"] ?? ":1"
        let executable = URL(
            fileURLWithPath: environment["EDITH_SSH_CLIPBOARD_EXECUTABLE"]
                ?? "/opt/homebrew/bin/ssh-clipboard")
        let machine = Machine(
            name: name, host: target, source: .sshConfigAlias(target),
            sshClipboardEnabled: true)

        try await SSHClipboardManager.shared.reconcile(machine)
        let connection = SSHConnection(machine: machine)
        try await connection.connect()
        let original = try await Self.local("/usr/bin/pbpaste").stdout

        try await Self.eventually {
            let local = try await Self.local(executable.path, ["status", "--json"])
            let remote = try await connection.run(
                "\"$HOME/.local/bin/ssh-clipboard\" status --json", timeout: 20)
            return local.succeeded && remote.succeeded
                && Self.connected(local.stdout) && Self.connected(remote.stdout)
        }

        let outgoingPayloads = [
            "edith-local-東京-🧑🏽‍💻-\(UUID().uuidString)",
            "edith-large-" + String(repeating: "x", count: 1024 * 1024),
        ]
        for outgoing in outgoingPayloads {
            _ = try await Self.local("/usr/bin/pbcopy", stdin: Data(outgoing.utf8))
            try await Self.eventually {
                let result = try await connection.run(
                    "DISPLAY=\(ShellQuote.quote(display)) xclip -selection clipboard -t 'text/plain;charset=utf-8' -o",
                    timeout: 20)
                return result.succeeded && result.stdoutText == outgoing
            }
        }

        var burst = ""
        for index in 0..<20 {
            burst = "edith-burst-\(index)-\(UUID().uuidString)"
            _ = try await Self.local("/usr/bin/pbcopy", stdin: Data(burst.utf8))
        }
        try await Self.eventually {
            let result = try await connection.run(
                "DISPLAY=\(ShellQuote.quote(display)) xclip -selection clipboard -t 'text/plain;charset=utf-8' -o",
                timeout: 20)
            return result.succeeded && result.stdoutText == burst
        }

        let incoming = "edith-remote-नमस्ते-🛰️-\(UUID().uuidString)"
        let remoteCopy = try await connection.run(
            "printf %s \(ShellQuote.quote(incoming)) | DISPLAY=\(ShellQuote.quote(display)) xclip -selection clipboard >/dev/null 2>&1 &",
            timeout: 20)
        #expect(remoteCopy.succeeded)
        try await Self.eventually {
            try await Self.local("/usr/bin/pbpaste").stdout == Data(incoming.utf8)
        }

        _ = try await Self.local("/usr/bin/pbcopy", stdin: original)

        var disabled = machine
        disabled.sshClipboardEnabled = false
        try await SSHClipboardManager.shared.reconcile(disabled, replacing: machine)
        try await Self.eventually {
            let local = try await Self.local(executable.path, ["status", "--json"])
            let remote = try await connection.run(
                "\"$HOME/.local/bin/ssh-clipboard\" status --json", timeout: 20)
            return local.succeeded && remote.succeeded && !Self.connected(local.stdout)
                && !Self.connected(remote.stdout) && Self.configured(local.stdout).isEmpty
        }

        try await SSHClipboardManager.shared.reconcile(machine)
        try await Self.eventually {
            let local = try await Self.local(executable.path, ["status", "--json"])
            let remote = try await connection.run(
                "\"$HOME/.local/bin/ssh-clipboard\" status --json", timeout: 20)
            return local.succeeded && remote.succeeded
                && Self.connected(local.stdout) && Self.connected(remote.stdout)
        }
        await connection.disconnect()
    }

    private static func connected(_ data: Data) -> Bool {
        !names("connected_peers", in: data).isEmpty
    }

    private static func configured(_ data: Data) -> [String] {
        names("configured_peers", in: data)
    }

    private static func names(_ key: String, in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let peers = object[key] as? [String]
        else {
            return []
        }
        return peers
    }

    private static func eventually(
        timeout: Duration = .seconds(30), operation: () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await operation() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SyncTimeout()
    }

    private static func local(
        _ executable: String, _ arguments: [String] = [], stdin: Data? = nil
    ) async throws -> SSHExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let status = await SSHConnection.waitForExit(process, timeout: 30)
        return SSHExecResult(
            status: status, stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile())
    }
}

private struct SyncTimeout: LocalizedError {
    var errorDescription: String? { "Timed out waiting for clipboard synchronization." }
}
