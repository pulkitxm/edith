@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite @MainActor struct MachineUsageSnapshotTests {
    private func snapshot(
        _ path: String = ".codex/sessions/test.jsonl", data: Data = Data("{}".utf8)
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "files": [
                [
                    "path": path, "modifiedAt": 1.0, "data": data.base64EncodedString(),
                ]
            ],
        ])
    }

    @Test func pathsRejectTraversalCredentialsAndUnsupportedSources() throws {
        for path in [
            "/.codex/sessions/test.jsonl", ".codex/sessions/../auth.json",
            ".codex/sessions//test.jsonl",
            ".codex/auth.json", ".codex/sessions/api-token.json", ".aws/credentials",
            ".openclaw/credentials/file.json", ".copilot/config.json", ".claude/projects/test.sock",
            ".local/share/kilo/private.db", ".kimi/sessions/settings.json",
            ".factory/sessions/session.jsonl",
            ".codex/sessions/node_modules/receipt.jsonl", ".codex/sessions/.git/receipt.jsonl",
        ] {
            #expect(!MachineUsageReceiptSnapshot.allowed(path))
            #expect(throws: (any Error).self) {
                try MachineUsageReceiptSnapshot.validate(snapshot(path))
            }
        }
        for path in [
            ".claude/projects/example/session.jsonl", ".codex/archived_sessions/receipt.jsonl",
            ".local/share/opencode/opencode.db", ".hermes/state.db",
            ".openclaw/agents/example/sessions/openclaw-agent.sqlite",
            ".factory/sessions/test.settings.json",
        ] { #expect(MachineUsageReceiptSnapshot.allowed(path)) }
    }

    @Test func snapshotLimitsRejectOversizeDuplicateAndMalformedEntries() throws {
        #expect(throws: (any Error).self) {
            try MachineUsageReceiptSnapshot.validate(
                snapshot(data: Data(repeating: 0, count: 8_388_609)))
        }
        let valid = try snapshot()
        try MachineUsageReceiptSnapshot.validate(valid)
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let files = try #require(object["files"] as? [[String: Any]])
        object["files"] = files + files
        #expect(throws: (any Error).self) {
            try MachineUsageReceiptSnapshot.validate(JSONSerialization.data(withJSONObject: object))
        }
        object["files"] = Array(repeating: files[0], count: 10_001)
        #expect(throws: (any Error).self) {
            try MachineUsageReceiptSnapshot.validate(JSONSerialization.data(withJSONObject: object))
        }
        object["files"] = files; object["command"] = "uname"
        #expect(throws: (any Error).self) {
            try MachineUsageReceiptSnapshot.validate(JSONSerialization.data(withJSONObject: object))
        }
        object.removeValue(forKey: "command"); object["version"] = true
        #expect(throws: (any Error).self) {
            try MachineUsageReceiptSnapshot.validate(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func sanitizedTierAndRemoteContextRejectSecretsAndCredentialURLs() throws {
        try MachineUsageReceiptSnapshot.validate(
            snapshot(".codex/config.toml", data: Data("service_tier = \"fast\"\n".utf8)))
        #expect(throws: (any Error).self) {
            try MachineUsageReceiptSnapshot.validate(
                snapshot(".codex/config.toml", data: Data("api_key = secret".utf8)))
        }
        var object = try #require(JSONSerialization.jsonObject(with: snapshot()) as? [String: Any])
        let project: [String: Any] = [
            "cwd": "/mock/worktree", "root": "/mock/repo", "repositoryID": "example.com/mock/repo",
            "repositoryName": "repo", "folderName": "worktree",
            "repositoryURL": "https://example.com/mock/repo", "worktree": "topic",
        ]
        object["context"] = [
            "machineID": UUID().uuidString, "projects": [project], "timeZone": "UTC",
        ]
        try MachineUsageReceiptSnapshot.validate(JSONSerialization.data(withJSONObject: object))
        var invalid = project; invalid["repositoryURL"] = "https://user:secret@example.com/repo"
        object["context"] = ["projects": [invalid], "timeZone": "UTC"]
        #expect(throws: (any Error).self) {
            try MachineUsageReceiptSnapshot.validate(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func snapshotTokensExpireAndInvalidateWithRegistryAndShutdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = MachineRegistry.Files(machines: root.appendingPathComponent("machines.json"))
        let machine = Machine(
            name: "Synthetic", host: "synthetic.invalid", createdAt: Date(timeIntervalSince1970: 1))
        MachineRegistry.add(machine, files)
        var now = Date(timeIntervalSince1970: 1)
        let store = MachineUsageSnapshotStore(files: files, now: { now })
        var receipt = try #require(JSONSerialization.jsonObject(with: snapshot()) as? [String: Any])
        receipt["context"] = ["machineID": machine.id.uuidString, "projects": []]
        let bytes = try JSONSerialization.data(withJSONObject: receipt)
        let descriptor = try store.insert(bytes, machine: machine)
        #expect(descriptor.sha256 == MachineUsageReceiptSnapshot.hash(bytes))
        #expect(descriptor.byteCount == bytes.count)
        func request(_ offset: Int = 0, maximum: Int = 262_144) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "collectionID": descriptor.collectionID.uuidString,
                "offset": offset, "maximumBytes": maximum,
            ])
        }
        let first = try store.execute("machines.usage.snapshot.result", payload: request())
        let object = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(object["finished"] as? Bool == true)
        #expect(Data(base64Encoded: object["data"] as? String ?? "") == bytes)
        #expect(throws: ExtensionPeerError.self) {
            try store.execute("machines.usage.snapshot.result", payload: request(-1))
        }
        #expect(throws: ExtensionPeerError.self) {
            try store.execute("machines.usage.snapshot.result", payload: request(maximum: 262_145))
        }
        now = now.addingTimeInterval(901)
        #expect(throws: ExtensionPeerError.self) {
            try store.execute("machines.usage.snapshot.result", payload: request())
        }
        let next = try store.insert(bytes, machine: machine)
        MachineRegistry.remove(id: machine.id, files)
        let nextRequest = Data(
            "{\"collectionID\":\"\(next.collectionID)\",\"offset\":0,\"maximumBytes\":10}".utf8)
        #expect(throws: ExtensionPeerError.self) {
            try store.execute("machines.usage.snapshot.result", payload: nextRequest)
        }
        store.shutdown()
        #expect(throws: ExtensionPeerError.self) { try store.insert(bytes, machine: machine) }
    }

    @Test func pythonSnapshotsSQLiteWALAndSkipsSecretsSymlinksAndSpecialFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try #require(
            MachineResources.url(forResource: "usage-snapshot", withExtension: "py"))
        let setup = """
            import os,pathlib,sqlite3,subprocess,sys
            home=pathlib.Path(sys.argv[1]); receipts=home/'.codex/sessions'; receipts.mkdir(parents=True)
            (receipts/'test.jsonl').write_text('{"cwd":"/synthetic/missing/worktree"}\\n')
            (home/'.codex/config.toml').write_text('service_tier = "fast"\\napi_key = "synthetic-secret"\\n')
            (receipts/'auth.json').write_text('private synthetic secret')
            (receipts/'linked.jsonl').symlink_to(receipts/'test.jsonl')
            os.mkfifo(receipts/'pipe.jsonl')
            db=home/'.hermes/state.db'; db.parent.mkdir()
            connection=sqlite3.connect(db); connection.execute('PRAGMA journal_mode=WAL')
            connection.execute('CREATE TABLE usage (tokens INTEGER)'); connection.execute('INSERT INTO usage VALUES (42)'); connection.commit()
            result=subprocess.run([sys.executable,sys.argv[2]],env={**os.environ,'HOME':str(home)},capture_output=True)
            sys.stdout.buffer.write(result.stdout); sys.stderr.buffer.write(result.stderr); sys.exit(result.returncode)
            """
        let output = Pipe(); let errors = Pipe()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", setup, root.path, script.path]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: error, as: UTF8.self))")
        try MachineUsageReceiptSnapshot.validate(data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try #require(object["files"] as? [[String: Any]])
        #expect(
            Set(files.compactMap { $0["path"] as? String }) == [
                ".codex/sessions/test.jsonl", ".hermes/state.db", ".codex/config.toml",
            ])
        let tier = try #require(files.first { $0["path"] as? String == ".codex/config.toml" })
        #expect(
            Data(base64Encoded: tier["data"] as? String ?? "")
                == Data("service_tier = \"fast\"\n".utf8))
        let context = try #require(object["context"] as? [String: Any])
        let projects = try #require(context["projects"] as? [[String: Any]])
        #expect(projects.first?["cwd"] as? String == "/synthetic/missing/worktree")
        let database = try #require(files.first { $0["path"] as? String == ".hermes/state.db" })
        let bytes = try #require(Data(base64Encoded: database["data"] as? String ?? ""))
        let copy = root.appendingPathComponent("backup.db"); try bytes.write(to: copy)
        let verify = Process(); let results = Pipe()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        verify.arguments = [
            "-c",
            "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('SELECT tokens FROM usage').fetchone()[0])",
            copy.path,
        ]
        verify.standardOutput = results; try verify.run()
        let value = results.fileHandleForReading.readDataToEndOfFile(); verify.waitUntilExit()
        #expect(verify.terminationStatus == 0)
        #expect(
            String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "42")
    }
}
