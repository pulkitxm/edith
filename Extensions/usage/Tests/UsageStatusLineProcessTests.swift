import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageStatusLineProcessTests {
    @Test func generatedHookUsesThePublicLauncherAndPrintsItsRawLine() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try launcher(in: root)
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":42}}}"#.utf8)
        let output = try execute(
            ClaudeStatusLine.command(executable: executable.path, wrapping: nil), input: input)
        #expect(output == Data("5h 42%\n".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("input.json")) == input)
        #expect(
            try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
                == "invoke\nusage\nusage.statusline.hook\n--json\n-\n--raw\n")
    }

    @Test(arguments: [false, true])
    func wrappedUserCommandReceivesExactInputAndSurvivesAnInactiveWorker(failing: Bool) throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try launcher(in: root, failing: failing)
        let previous = "printf '%s\\n' 'synthetic --then \"quoted\" output'; /bin/cat"
        let command = ClaudeStatusLine.command(executable: executable.path, wrapping: previous)
        #expect(ClaudeStatusLine.wrappedCommand(in: command) == previous)
        let input = Data("{\"synthetic\":true}\n\n".utf8)
        let output = try execute(command, input: input)
        #expect(output == Data("synthetic --then \"quoted\" output\n".utf8) + input)
        #expect(try Data(contentsOf: root.appendingPathComponent("input.json")) == input)
    }

    @Test func oversizedInputCannotReachEitherCommandAndTemporaryFilesAreRemoved() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try launcher(in: root)
        let command = ClaudeStatusLine.command(
            executable: executable.path, wrapping: "printf unexpected")
        let output = try execute(
            command, input: Data(repeating: 32, count: 524_289), temporary: root, status: 1)
        #expect(output.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("arguments.txt").path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
                !$0.hasPrefix("edith-statusline.")
            })
    }

    private func launcher(in root: URL, failing: Bool = false) throws -> URL {
        let file = root.appendingPathComponent("ed 'synthetic' launcher")
        let text = """
            #!/bin/sh
            cd "$(dirname "$0")" || exit 1
            printf '%s\\n' "$@" > arguments.txt
            /bin/cat > input.json
            \(failing ? "exit 1" : "printf '5h 42%%\\n'")
            """
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func execute(_ command: String, input: Data, temporary: URL? = nil, status: Int32 = 0)
        throws -> Data
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let temporary {
            process.environment = ProcessInfo.processInfo.environment.merging([
                "TMPDIR": temporary.path
            ]) { _, value in value }
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == status)
        return output
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
