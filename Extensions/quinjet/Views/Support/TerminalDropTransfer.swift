import EdithExtensionSupport
import Foundation

enum TerminalDropTransfer {
    static func upload(_ urls: [URL], over connection: SSHConnection) async throws -> [String] {
        guard !urls.isEmpty, urls.count <= 64 else { throw ExtensionPeerError.invalidRequest }
        try await connection.connect()
        let platform = await connection.remotePlatform ?? .linux
        let command =
            platform == .windows
            ? PowerShell.command(
                "$p=Join-Path ([IO.Path]::GetTempPath()) ('edith-drop-'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($p)|Out-Null;[Console]::Out.Write($p)"
            )
            : "mktemp -d /tmp/edith-drop.XXXXXXXX"
        let result = try await connection.run(command, timeout: 15)
        let directory = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.utf8.count <= 4_096,
            platform == .windows
                ? FileListing.isWindowsPath(directory) : directory.hasPrefix("/tmp/edith-drop."),
            !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ExtensionPeerError.rejected(
                "The machine did not provide a temporary upload directory.")
        }
        var paths: [String] = []
        do {
            for url in urls {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize,
                    FileManager.default.isReadableFile(atPath: url.path)
                else {
                    throw ExtensionPeerError.rejected(
                        "Choose a readable file to drop into the terminal.")
                }
                let path = remotePath(for: url, directory: directory)
                let sftpPath =
                    platform == .windows
                    ? "/" + path.replacingOccurrences(of: "\\", with: "/") : path
                let batch = "put " + (try quote(url.path)) + " " + (try quote(sftpPath)) + "\n"
                let request = CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/sftp"),
                    arguments: [
                        "-b", "-", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o",
                        "ControlPath=" + connection.controlSocketPath, "-o", "ProxyCommand=false",
                        connection.machine.sshTarget,
                    ], environment: CLIToolEnvironment.sanitized(), timeout: 900,
                    maximumOutputBytes: 65_536, standardInputData: Data(batch.utf8),
                    terminatesProcessGroup: true)
                let uploaded = try await CLICommandRunner.run(request, onLine: { _ in })
                guard uploaded.terminationStatus == 0 else {
                    throw ExtensionPeerError.rejected(
                        uploaded.standardError.isEmpty
                            ? "The file could not be uploaded. Reconnect the saved machine and retry."
                            : uploaded.standardError)
                }
                let verify =
                    platform == .windows
                    ? PowerShell.command(
                        "[Console]::Out.Write((Get-Item -LiteralPath " + PowerShell.literal(path)
                            + ").Length)") : "wc -c < " + POSIXQuote.quote(path)
                let receipt = try await connection.run(verify, timeout: 15)
                guard
                    Int(receipt.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) == size
                else {
                    throw ExtensionPeerError.rejected(
                        "The remote file size differs from the uploaded file.")
                }
                paths.append(path)
            }
            return paths
        } catch {
            let cleanup =
                platform == .windows
                ? PowerShell.command(
                    "Remove-Item -LiteralPath " + PowerShell.literal(directory) + " -Recurse -Force"
                ) : "rm -rf -- " + POSIXQuote.quote(directory)
            let cleanupTask = Task {
                _ = try? await connection.run(cleanup, timeout: 15)
            }
            await cleanupTask.value
            throw error
        }
    }
    static func quote(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 8_192,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ExtensionPeerError.invalidRequest }
        return "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
                of: "\"", with: "\\\"") + "\""
    }
    static func remotePath(
        for url: URL, directory: String, identifier: String = UUID().uuidString.lowercased()
    ) -> String {
        let safe = url.lastPathComponent.map {
            $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_"
        }
        let name = safe.isEmpty ? "file" : String(safe.prefix(96))
        return FileListing.join(parent: directory, name: "edith-drop-\(identifier)-\(name)")
    }
}
