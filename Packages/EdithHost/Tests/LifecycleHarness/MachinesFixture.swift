import CryptoKit
import EdithHostCore
import EdithExtensionSupport
import Foundation

@MainActor enum MachinesFixture {
    static let machineID = "11111111-2222-3333-4444-555555555555"
    private static var previousCollectionID: String?
    private static var receiptHash: String?

    static func seed(identity: HostIdentity, home: URL) throws {
        setenv("EDITH_EXTENSION_FIXTURE_HOME", home.path, 1)
        let directory = identity.extensionDirectory("machines")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let machine: [String: Any] = [
            "id": machineID, "name": "Synthetic builder", "host": "builder.invalid",
            "port": 22, "username": "test", "auth": ["agent": [:]], "source": ["manual": [:]],
            "sshClipboardEnabled": false, "createdAt": "2026-10-09T00:00:00Z",
        ]
        try JSONSerialization.data(withJSONObject: [machine]).write(
            to: directory.appendingPathComponent("machines.json"))
        let forward: [String: Any] = [
            "id": "22222222-3333-4444-5555-666666666666", "machineID": machineID,
            "localPort": 15432, "remoteHost": "localhost", "remotePort": 5432,
            "title": "Synthetic database",
        ]
        try JSONSerialization.data(withJSONObject: [forward]).write(
            to: directory.appendingPathComponent("forwards.json"))
        var receipt = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sessionId": "synthetic-remote-session", "requestId": "synthetic-remote-request",
            "cwd": "C:/Synthetic Projects/Worktree", "costUSD": 1.25,
            "message": [
                "id": "synthetic-remote-message", "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": 40, "output_tokens": 8],
            ],
        ])
        receipt.append(10)
        receiptHash = SHA256.hash(data: receipt).map { String(format: "%02x", $0) }.joined()
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "files": [
                [
                    "path": ".claude/projects/synthetic/session.jsonl",
                    "modifiedAt": Date().timeIntervalSince1970,
                    "data": receipt.base64EncodedString(),
                ]
            ],
            "context": [
                "timeZone": "UTC",
                "projects": [
                    [
                        "cwd": "C:/Synthetic Projects/Worktree", "root": "C:/Synthetic Projects",
                        "repositoryID": "github.com/example/synthetic-remote",
                        "repositoryName": "Synthetic remote", "folderName": "Worktree",
                        "repositoryURL": "https://github.com/example/synthetic-remote",
                        "worktree": "topic",
                    ]
                ],
            ],
        ])
        let raw = home.appendingPathComponent("machines-raw-snapshot.json")
        try snapshot.write(to: raw, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: raw.path)
    }

    static func verify(_ endpoint: ExtensionPeerEndpoint, identity: HostIdentity) async throws {
        let hosts = try await call(endpoint, "machines.companion.hosts", [:])
        let machines = hosts["machines"] as? [[String: Any]]
        guard machines?.count == 1, machines?.first?["id"] as? String == machineID,
            machines?.first?["sshTarget"] as? String == "test@builder.invalid"
        else { throw HostWorkerError.invalidResponse }
        let output = try await call(
            endpoint, "machines.companion.run",
            [
                "machineID": machineID,
                "command": "printf synthetic", "stdinbase64": NSNull(), "timeout": 30,
            ])
        guard output["output"] as? String == "synthetic runtime output" else {
            throw HostWorkerError.invalidResponse
        }
        let connected = try await call(
            endpoint, "machines.companion.forward",
            [
                "machineID": machineID,
                "localPort": 15432, "remotePort": 5432,
            ])
        guard connected["connected"] as? Bool == true else { throw HostWorkerError.invalidResponse }
        let prepared = try await call(endpoint, "machines.forward.prepare", ["ports": [15432]])
        guard prepared["prepared"] as? Bool == true,
            prepared["name"] as? String == "Synthetic builder"
        else { throw HostWorkerError.invalidResponse }
        for (command, input) in [
            (
                "machines.companion.run",
                ["machineID": machineID, "command": "uname", "timeout": 1801]
            ),
            ("machines.forward.prepare", ["ports": [9999]]),
            ("machines.forward.prepare", ["ports": [15432, 15432]]),
            (
                "machines.usage.collect",
                ["machineID": machineID, "force": true, "command": "uname"]
            ),
        ] as [(String, [String: Any])] {
            try await reject(endpoint, command, input)
        }
        if let previousCollectionID {
            try await reject(
                endpoint, "machines.usage.result",
                [
                    "collectionID": previousCollectionID,
                    "offset": 0, "maximumBytes": 64,
                ])
        }
        let descriptor = try await call(
            endpoint, "machines.usage.collect", ["machineID": machineID, "force": true])
        guard let id = descriptor["collectionID"] as? String, UUID(uuidString: id) != nil,
            let count = descriptor["byteCount"] as? Int, count > 0, count <= 67_108_864,
            let hash = descriptor["sha256"] as? String
        else { throw HostWorkerError.invalidResponse }
        var document = Data()
        while document.count < count {
            let chunk = try await call(
                endpoint, "machines.usage.result",
                [
                    "collectionID": id,
                    "offset": document.count, "maximumBytes": 31,
                ])
            guard chunk["offset"] as? Int == document.count, let encoded = chunk["data"] as? String,
                let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 31
            else { throw HostWorkerError.invalidResponse }
            document.append(bytes)
            guard chunk["finished"] as? Bool == (document.count == count) else {
                throw HostWorkerError.invalidResponse
            }
        }
        guard SHA256.hash(data: document).map({ String(format: "%02x", $0) }).joined() == hash,
            let data = try JSONSerialization.jsonObject(with: document) as? [String: Any],
            data["schemaVersion"] as? Int == 8,
            let totals = data["totals"] as? [String: Any],
            totals["tokens"] as? Double == 48, totals["cost"] as? Double == 1.25,
            let daily = data["daily"] as? [[String: Any]],
            let project = daily.flatMap({ $0["projects"] as? [[String: Any]] ?? [] }).first,
            project["repositoryID"] as? String == "github.com/example/synthetic-remote",
            project["path"] as? String == "C:/Synthetic Projects"
        else { throw HostWorkerError.invalidResponse }
        for input in [
            ["collectionID": id, "offset": -1, "maximumBytes": 64],
            ["collectionID": id, "offset": 0, "maximumBytes": 262145],
            ["collectionID": UUID().uuidString, "offset": 0, "maximumBytes": 64],
        ] as [[String: Any]] {
            try await reject(endpoint, "machines.usage.result", input)
        }
        _ = try await call(endpoint, "machines.usage.cancel", ["collectionID": id])
        try await reject(
            endpoint, "machines.usage.result",
            ["collectionID": id, "offset": 0, "maximumBytes": 64])
        try verifyArchive(identity: identity)
        let retained = try await call(
            endpoint, "machines.usage.collect", ["machineID": machineID, "force": true])
        previousCollectionID = retained["collectionID"] as? String
        try verifyArchive(identity: identity)
    }

    private static func verifyArchive(identity: HostIdentity) throws {
        let usage = identity.extensionDirectory("usage").appendingPathComponent("data")
        let stages = usage.appendingPathComponent("remote-staging")
        guard try FileManager.default.contentsOfDirectory(atPath: stages.path).isEmpty else {
            throw HostWorkerError.invalidResponse
        }
        let database = usage.appendingPathComponent(
            "remote-archives/\(machineID.lowercased())/native-usage-history/usage.sqlite")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", "-json", database.path,
            "SELECT hash,payload FROM records;",
        ]
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let records = try JSONSerialization.jsonObject(with: output) as? [[String: Any]],
            records.count == 1, let payload = records[0]["payload"] as? String,
            let hash = records[0]["hash"] as? String,
            SHA256.hash(data: Data(payload.utf8)).map({ String(format: "%02x", $0) }).joined()
                == hash
        else { throw HostWorkerError.invalidResponse }
        let files = Process()
        let fileOutput = Pipe()
        files.executableURL = process.executableURL
        files.arguments = ["-readonly", "-json", database.path, "SELECT hash FROM files;"]
        files.standardOutput = fileOutput
        try files.run()
        let fileBytes = fileOutput.fileHandleForReading.readDataToEndOfFile()
        files.waitUntilExit()
        guard files.terminationStatus == 0,
            let rows = try JSONSerialization.jsonObject(with: fileBytes) as? [[String: Any]],
            rows.count == 1, rows[0]["hash"] as? String == receiptHash
        else {
            throw HostWorkerError.invalidResponse
        }
    }

    private static func call(
        _ endpoint: ExtensionPeerEndpoint, _ command: String, _ input: [String: Any]
    ) async throws -> [String: Any] {
        let data = try await endpoint.invoke(
            command, payload: JSONSerialization.data(withJSONObject: input), timeout: 10)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostWorkerError.invalidResponse
        }
        return object
    }

    private static func reject(
        _ endpoint: ExtensionPeerEndpoint, _ command: String, _ input: [String: Any]
    ) async throws {
        do {
            _ = try await call(endpoint, command, input)
            throw HostWorkerError.invalidResponse
        } catch HostWorkerError.invalidResponse { throw HostWorkerError.invalidResponse } catch {}
    }
}
