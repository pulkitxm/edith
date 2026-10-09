@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct MachineWindowsUsageTests {
    private func sqlitePython() throws -> URL {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        let candidates =
            directories.map { String($0) + "/python3" }
            + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: candidate)
            process.arguments = [
                "-c",
                "import sqlite3,sys; sys.exit(0 if hasattr(sqlite3.Connection,'serialize') else 1)",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            if process.terminationStatus == 0 { return URL(fileURLWithPath: candidate) }
        }
        throw ExtensionPeerError.rejected(
            "Windows WAL fixtures require Python with SQLite serialization.")
    }

    @Test func powershellUsesTheExistingGitBashTransportAndStdinWithoutLongArguments() throws {
        let command = try MachineRemoteUsageOperation.command(platform: .windows, force: true)
        let encoded = try #require(command.components(separatedBy: "-EncodedCommand ").last)
        let bytes = try #require(Data(base64Encoded: encoded))
        let script = try #require(String(data: bytes, encoding: .utf16LittleEndian))
        #expect(command.utf8.count < 8_192)
        #expect(script.contains("Git/bin/bash.exe"))
        #expect(
            script.contains(
                "& $gitBash -lc "
                    + PowerShell.literal(
                        MachineRemoteUsageOperation.shellScript(platform: .windows))))
        #expect(script.contains("Git Bash is required"))
        #expect(script.contains("cygpath -aw"))
        #expect(script.contains("Install Python 3.8 or newer"))
        #expect(script.contains("python=(py -3)"))
        #expect(!script.contains("bun"))
        #expect(!script.contains("curl"))
        #expect(!script.contains("usage-snapshot.py"))
        let input = String(decoding: try MachineRemoteUsageOperation.input(), as: UTF8.self)
        #expect(input.contains("destination.serialize()"))
        #expect(input.contains("source.backup(destination"))
    }

    @Test func gitBashWindowsFixturePreservesDriveMetadataAndSQLiteWALWithoutDiskStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "windows snapshot ' \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try sqlitePython()
        let snapshot = try #require(
            MachineResources.url(forResource: "usage-snapshot", withExtension: "py"))
        let shell = MachineRemoteUsageOperation.shellScript(platform: .windows)
        let setup = #"""
            import base64,json,os,pathlib,sqlite3,subprocess,sys
            home=pathlib.Path(sys.argv[1]); binaries=home/'bin'; binaries.mkdir()
            (binaries/'python3').symlink_to(sys.executable)
            cygpath=binaries/'cygpath'; cygpath.write_text('#!/bin/bash\nprintf "%s\\n" "$HOME"\n'); cygpath.chmod(0o700)
            journals=home/'.codex/sessions'; journals.mkdir(parents=True)
            cwd='C:\\Synthetic Projects\\Repository\\Worktree'
            (journals/'session.jsonl').write_text(json.dumps({'cwd':cwd,'tokens':42})+'\n')
            (journals/'linked.jsonl').symlink_to(journals/'session.jsonl')
            (journals/'auth.json').write_text('synthetic secret')
            dependency=journals/'node_modules'; dependency.mkdir(); (dependency/'secret.json').write_text('synthetic secret')
            db=home/'.hermes/state.db'; db.parent.mkdir()
            connection=sqlite3.connect(db); connection.execute('PRAGMA journal_mode=WAL')
            connection.execute('CREATE TABLE usage(tokens INTEGER)'); connection.execute('INSERT INTO usage VALUES(42)'); connection.commit()
            temporary=home/'temporary'; temporary.mkdir()
            environment={**os.environ,'HOME':str(home),'PATH':str(binaries),'TMPDIR':str(temporary)}
            result=subprocess.run(['/bin/bash','-c',sys.argv[3]],input=pathlib.Path(sys.argv[2]).read_bytes(),capture_output=True,env=environment)
            if result.returncode: sys.stderr.buffer.write(result.stderr); sys.exit(result.returncode)
            receipt=json.loads(result.stdout)
            backup=next(file for file in receipt['files'] if file['path']=='.hermes/state.db')
            database=sqlite3.connect(':memory:'); database.deserialize(base64.b64decode(backup['data']))
            assert database.execute('SELECT tokens FROM usage').fetchone()[0]==42
            assert list(temporary.iterdir())==[]
            assert receipt['context']['projects'][0]['cwd']==cwd
            assert receipt['context']['projects'][0]['folderName']=='Worktree'
            assert {file['path'] for file in receipt['files']}=={'.codex/sessions/session.jsonl','.hermes/state.db'}
            sys.stdout.buffer.write(result.stdout)
            """#
        let output = Pipe(); let errors = Pipe()
        let process = Process(); process.executableURL = python
        process.arguments = ["-c", setup, root.path, snapshot.path, shell]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: error, as: UTF8.self))")
        try MachineUsageReceiptSnapshot.validate(data)
    }

    @Test func missingPythonIsAnActionableFailureWithNoDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cygpath = root.appendingPathComponent("cygpath")
        try Data("#!/bin/bash\nprintf '%s\\n' \"$HOME\"\n".utf8).write(to: cygpath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: cygpath.path)
        let result = try await CLICommandRunner.run(
            .init(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", MachineRemoteUsageOperation.shellScript(platform: .windows)],
                environment: ["PATH": root.path, "HOME": root.path], timeout: 10,
                maximumOutputBytes: 16_384,
                standardInputData: try MachineRemoteUsageOperation.input(),
                terminatesProcessGroup: true), onLine: { _ in })
        #expect(result.terminationStatus == 69)
        #expect(result.standardOutputData.isEmpty)
        #expect(result.standardError.contains("Install Python 3.8 or newer"))
    }

    @Test func windowsEnumeratesAllOriginalProviderRootsAndPreservesForwardDrivePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = [
            ".claude/projects/p/event.jsonl",
            "Library/Application Support/Claude/local-agent-mode-sessions/s/.claude/projects/p/event.jsonl",
            ".codex/sessions/event.jsonl", ".codex/archived_sessions/event.jsonl",
            ".local/share/opencode/storage/message/event.json", ".cursor/chats/event.json",
            ".pi/agent/sessions/event.jsonl", ".commandcode/projects/event.jsonl",
            ".local/share/amp/event.json", ".factory/sessions/event.settings.json",
            ".config/manicode/projects/chat-messages.json",
            ".config/manicode-dev/projects/chat-messages.json",
            ".config/manicode-staging/projects/chat-messages.json", ".hermes/sessions/event.jsonl",
            ".local/share/goose/sessions/event.jsonl",
            ".local/share/Block/goose/sessions/event.jsonl",
            "Library/Application Support/goose/sessions/event.jsonl",
            ".local/share/kilo/event.json",
            ".gemini/tmp/event.json", ".copilot/sessions/event.jsonl", ".kimi/sessions/wire.jsonl",
            ".kimi-code/sessions/wire.jsonl", ".qwen/projects/event.jsonl",
            ".openclaw/agents/p/sessions/event.jsonl", ".clawdbot/agents/p/sessions/event.jsonl",
            ".moltbot/agents/p/sessions/event.jsonl", ".moldbot/agents/p/sessions/event.jsonl",
            ".grok/sessions/updates.jsonl", ".grok/sessions/summary.json",
        ]
        let receipt = Data(
            "{\"cwd\":\"C:/Synthetic Projects/Repository's Worktree\",\"tokens\":42}".utf8)
        for source in sources {
            let url = root.appendingPathComponent(source)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try receipt.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: url.path)
        }
        let tier = root.appendingPathComponent(".codex/config.toml")
        try Data("service_tier = \"fast\"\napi_key = \"synthetic secret\"\n".utf8).write(to: tier)
        let output = Pipe(); let errors = Pipe(); let input = Pipe()
        let process = Process(); process.executableURL = try sqlitePython();
        process.arguments = ["-"]
        process.environment = [
            "HOME": root.path, "EDITH_USAGE_SNAPSHOT_WINDOWS": "1", "PATH": root.path,
        ]
        process.standardInput = input; process.standardOutput = output;
        process.standardError = errors
        try process.run(); input.fileHandleForWriting.write(try MachineRemoteUsageOperation.input())
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(String(decoding: error, as: UTF8.self))")
        try MachineUsageReceiptSnapshot.validate(data)
        let snapshot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try #require(snapshot["files"] as? [[String: Any]])
        #expect(
            Set(files.compactMap { $0["path"] as? String }) == Set(sources + [".codex/config.toml"])
        )
        #expect(
            files.filter { $0["path"] as? String != ".codex/config.toml" }.allSatisfy {
                $0["modifiedAt"] as? Double == 42
            })
        let config = try #require(files.first { $0["path"] as? String == ".codex/config.toml" })
        #expect(
            config["data"] as? String
                == Data("service_tier = \"fast\"\n".utf8).base64EncodedString())
        let context = try #require(snapshot["context"] as? [String: Any])
        let projects = try #require(context["projects"] as? [[String: Any]])
        #expect(projects.count == 1)
        #expect(projects.first?["cwd"] as? String == "C:/Synthetic Projects/Repository's Worktree")
        #expect(projects.first?["root"] as? String == "C:/Synthetic Projects/Repository's Worktree")
        #expect(projects.first?["folderName"] as? String == "Repository's Worktree")
    }

    @Test func windowsMissingSQLiteSerializationAndUnsafeRootsFailExplicitly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".hermes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try sqlitePython()
        let setup = Process(); setup.executableURL = python
        setup.arguments = [
            "-c",
            "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE t(i)'); c.commit()",
            root.appendingPathComponent(".hermes/state.db").path,
        ]
        try setup.run(); setup.waitUntilExit(); try #require(setup.terminationStatus == 0)
        let snapshot = try MachineRemoteUsageOperation.input()
        let environment = ["HOME": root.path, "EDITH_USAGE_SNAPSHOT_WINDOWS": "1"]
        let result = try await CLICommandRunner.run(
            .init(
                executableURL: python,
                arguments: [
                    "-c",
                    "import sqlite3,sys; sqlite3.Connection=type('WithoutSerialization',(),{}); exec(compile(sys.stdin.read(),'snapshot','exec'))",
                ],
                environment: environment, timeout: 10, maximumOutputBytes: 16_384,
                standardInputData: snapshot, terminatesProcessGroup: true), onLine: { _ in })
        #expect(result.terminationStatus != 0 && result.standardOutputData.isEmpty)
        #expect(result.standardError.contains("Python 3.11 or newer with SQLite serialization"))
        let codex = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: codex.appendingPathComponent("sessions"), withDestinationURL: root)
        let unsafe = try await CLICommandRunner.run(
            .init(
                executableURL: python, arguments: ["-"], environment: environment,
                timeout: 10, maximumOutputBytes: 16_384, standardInputData: snapshot,
                terminatesProcessGroup: true), onLine: { _ in })
        #expect(unsafe.terminationStatus != 0 && unsafe.standardOutputData.isEmpty)
        #expect(unsafe.standardError.contains("symbolic link or Windows junction"))
    }
}
