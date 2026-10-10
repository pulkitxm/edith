import EdithExtensionSupport
import EdithHostCore
import Foundation

extension HostLifecycleHarness {
    @MainActor static func verifyDatabase(
        _ endpoint: ExtensionPeerEndpoint, seed: Bool, headlessCLI: Bool
    )
        async throws
    {
        let id = "AE4B7B4D-2044-412F-8AF7-F85B13289AAF"
        func failure(_ message: String) -> NSError {
            NSError(
                domain: "DatabaseFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        func invoke(_ command: String, _ request: [String: Any]) async throws -> [String: Any] {
            let data = try await endpoint.invoke(
                "database.execute",
                payload: JSONSerialization.data(withJSONObject: [
                    "version": 1, "command": command, "request": request,
                ]))
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let result = response["result"] as? [String: Any],
                result["status"] as? String == "succeeded",
                let payload = result["payload"] as? [String: Any]
            else {
                throw failure(
                    "Invalid SQLite fixture response for \(command): \(String(decoding: data, as: UTF8.self))"
                )
            }
            return payload
        }
        if seed {
            let definition: [String: Any] = [
                "version": 1, "id": ["rawValue": id], "displayName": "Synthetic SQLite",
                "productHint": "sqlite", "location": ["kind": "memory"],
                "namespaces": [:], "deploymentMode": "embedded",
                "authentication": ["kind": "none", "secretReferences": []],
                "tls": ["mode": "disabled", "verification": "none"],
                "limits": ["connectionTimeout": 10000, "operationTimeout": 20000, "poolSize": 1],
                "readOnlyPolicy": "disabled", "productionPolicy": "standard",
                "environment": ["kind": "testing", "label": "Synthetic", "protection": "standard"],
                "tags": [], "isFavorite": true, "options": [], "createdAt": 800000000,
                "updatedAt": 800000000,
            ]
            _ = try await invoke(
                "database.connection.save", ["version": 1, "connection": definition])
        }
        let listed = try await invoke(
            "database.connection.list",
            [
                "version": 1,
                "search": [
                    "favoritesOnly": false, "products": [], "environments": [], "tags": [],
                    "order": "recentlyUsed", "limit": 100, "offset": 0,
                ],
            ])
        guard let connections = listed["connections"] as? [[String: Any]], connections.count == 1,
            connections[0]["displayName"] as? String == "Synthetic SQLite"
        else { throw failure("The persisted synthetic connection was not restored") }
        func operation() -> [String: Any] {
            [
                "operationID": ["rawValue": UUID().uuidString],
                "deadline": Date().addingTimeInterval(30).timeIntervalSinceReferenceDate,
            ]
        }
        _ = try await invoke(
            "database.connection.connect",
            [
                "version": 1, "connectionID": ["rawValue": id], "operation": operation(),
            ])
        let queried = try await invoke(
            "database.query",
            [
                "version": 1, "target": ["connectionID": ["rawValue": id]],
                "language": "sql", "command": "SELECT 'synthetic-value' AS result",
                "parameters": [],
                "page": ["pageSize": 20, "sorts": [], "consistency": "productDefault"],
                "operation": operation(),
            ])
        guard
            String(decoding: try JSONSerialization.data(withJSONObject: queried), as: UTF8.self)
                .contains("synthetic-value")
        else { throw failure("The SQLite query did not return the synthetic value") }
        let catalogData = try await endpoint.invoke(
            "database.cli.catalog", payload: Data("{}".utf8))
        guard let catalog = try JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
            let routes = catalog["commands"] as? [[String: Any]], routes.count == 39,
            routes.contains(where: { $0["route"] as? [String] == ["database", "mcp"] }),
            routes.contains(where: {
                $0["route"] as? [String] == ["database", "mutations", "apply"]
            })
        else { throw failure("The original Database command catalog was not restored") }
        let queryRequest = try ExtensionCLIRequest(
            arguments: ["query", id, "--json"],
            standardInput: Data("SELECT 'synthetic-cli-value' AS result".utf8),
            workingDirectory: "/tmp", interactive: true)
        let cli = try JSONDecoder().decode(
            ExtensionCLIReply.self,
            from: await endpoint.invoke(
                "database.cli", payload: JSONEncoder().encode(queryRequest)))
        guard cli.exitCode == 0, cli.stderr.isEmpty, cli.stdout.contains("synthetic-cli-value")
        else { throw failure("The owned CLI did not preserve query stdin and context") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SELECT 'synthetic-relative-query' AS result".utf8).write(
            to: directory.appendingPathComponent("query.sql"))
        let fileRequest = try ExtensionCLIRequest(
            arguments: ["query", id, "--json", "--file", "query.sql"],
            workingDirectory: directory.path)
        let fileReply = try JSONDecoder().decode(
            ExtensionCLIReply.self,
            from: await endpoint.invoke(
                "database.cli", payload: JSONEncoder().encode(fileRequest)))
        guard fileReply.exitCode == 0, fileReply.stderr.isEmpty,
            fileReply.stdout.contains("synthetic-relative-query")
        else { throw failure("The owned CLI did not resolve the request working directory") }
        try await verifyDatabaseMCP(endpoint)
        var tile = SurfaceTile(.databases)
        tile.sourceIDs = [id]
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.snapshot", payload: request.encoded(providerID: "database")),
            providerID: "database")
        guard snapshot.rows.count == 1, snapshot.rows[0].title == "Synthetic SQLite",
            snapshot.rows[0].sourceID == id, let action = snapshot.rows[0].actions.first
        else { throw failure("The saved connection surface did not expose its source and action") }
        if !headlessCLI {
            _ = try await endpoint.invoke(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: action.id)
                    .encoded(providerID: "database"))
        }
        _ = try await invoke(
            "database.connection.disconnect",
            [
                "version": 1, "connectionID": ["rawValue": id], "operation": operation(),
            ])
    }

    @MainActor private static func verifyDatabaseMCP(_ endpoint: ExtensionPeerEndpoint) async throws
    {
        func failure(_ message: String) -> NSError {
            NSError(
                domain: "DatabaseMCPFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        func invoke<Request: Encodable, Reply: Decodable>(
            _ operation: String, _ request: Request,
            as type: Reply.Type
        ) async throws -> Reply {
            try JSONDecoder().decode(
                type,
                from: await endpoint.invoke(
                    "database.cli.stream." + operation, payload: JSONEncoder().encode(request)))
        }
        let initialize =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Synthetic MCP","version":"1"}}}"#
            + "\n"
        func start() async throws -> ExtensionCLIStreamHandle {
            try await invoke(
                "start",
                ExtensionCLIStreamStart(
                    owner: "database", session: UUID(),
                    request: try ExtensionCLIRequest(
                        arguments: ["mcp"], standardInput: Data(initialize.utf8),
                        workingDirectory: "/tmp", interactive: true), deadline: 30),
                as: ExtensionCLIStreamHandle.self)
        }
        func read(
            _ handle: ExtensionCLIStreamHandle, sequence: UInt64 = 0,
            stopWhenRunningReply: Bool = false
        )
            async throws
            -> (Data, ExtensionCLIStreamFrame)
        {
            var cursor = sequence
            var data = Data()
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                let frame = try await invoke(
                    "read", ExtensionCLIStreamRead(handle: handle, sequence: cursor),
                    as: ExtensionCLIStreamFrame.self)
                try frame.validate()
                cursor = frame.nextSequence
                for chunk in frame.chunks {
                    guard chunk.channel == .stdout else {
                        throw failure("MCP emitted unexpected diagnostics")
                    }
                    data.append(chunk.data)
                }
                if frame.state != .running || (stopWhenRunningReply && data.contains(10)) {
                    return (data, frame)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw failure("The MCP reply deadline expired")
        }
        let handle = try await start()
        let messages =
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
            + #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"database_connections","arguments":{"action":"list"}}}"#
            + "\n"
        let bytes = Data(messages.utf8)
        var sequence: UInt64 = 0
        for offset in stride(from: 0, to: bytes.count, by: 7) {
            let end = min(offset + 7, bytes.count)
            let payload = try JSONSerialization.data(withJSONObject: [
                "handle": JSONSerialization.jsonObject(with: JSONEncoder().encode(handle)),
                "sequence": sequence,
                "data": bytes.subdata(in: offset..<end).base64EncodedString(),
                "end": end == bytes.count,
            ])
            let reply = try await endpoint.invoke("database.cli.stream.write", payload: payload)
            guard let ack = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                ack["accepted"] as? Bool == true, let next = ack["nextSequence"] as? UInt64,
                next == sequence + 1
            else { throw failure("Bounded MCP input was rejected") }
            sequence = next
        }
        let (output, frame) = try await read(handle)
        guard frame.state == .completed, frame.exitCode == 0 else {
            throw failure("The owned MCP stream did not complete after EOF")
        }
        let replies = try output.split(separator: 10).map {
            try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
        guard Set(replies.compactMap { $0?["id"] as? Int }) == [1, 2, 3],
            let catalogReply = replies.compactMap({ $0 }).first(where: { $0["id"] as? Int == 2 }),
            let result = catalogReply["result"] as? [String: Any],
            (result["tools"] as? [[String: Any]])?.count == 10,
            String(decoding: output, as: UTF8.self).contains("Synthetic SQLite")
        else { throw failure("The original MCP catalog or owned connection reply was lost") }
        _ = try await endpoint.invoke(
            "database.cli.stream.end", payload: JSONEncoder().encode(handle))
        let cancelled = try await start()
        let (_, beforeCancel) = try await read(cancelled, stopWhenRunningReply: true)
        _ = try await endpoint.invoke(
            "database.cli.stream.cancel", payload: JSONEncoder().encode(cancelled))
        let (_, cancelledFrame) = try await read(cancelled, sequence: beforeCancel.nextSequence)
        guard cancelledFrame.state == .cancelled else {
            throw failure("MCP cancellation was not acknowledged")
        }
        _ = try await endpoint.invoke(
            "database.cli.stream.end", payload: JSONEncoder().encode(cancelled))
        let active = try await start()
        let (_, activeFrame) = try await read(active, stopWhenRunningReply: true)
        guard activeFrame.state == .running else {
            throw failure("The lifecycle MCP stream was not active")
        }
    }
}
