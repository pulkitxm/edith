import CryptoKit
import EdithHostCore
import EdithExtensionSupport
import Foundation

@MainActor enum MachinesFixture {
    static let machineID = "11111111-2222-3333-4444-555555555555"
    private static var previousCollectionID: String?

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
    }

    static func verify(_ endpoint: ExtensionPeerEndpoint) async throws {
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
            data["schemaVersion"] as? Int == 8
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
        let retained = try await call(
            endpoint, "machines.usage.collect", ["machineID": machineID, "force": true])
        previousCollectionID = retained["collectionID"] as? String
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
