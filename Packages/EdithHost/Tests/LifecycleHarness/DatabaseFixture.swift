import EdithExtensionSupport
import EdithHostCore
import Foundation

extension HostLifecycleHarness {
    @MainActor static func verifyDatabase(_ endpoint: ExtensionPeerEndpoint, seed: Bool)
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
        _ = try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(snapshot: request, actionID: action.id)
                .encoded(providerID: "database"))
        _ = try await invoke(
            "database.connection.disconnect",
            [
                "version": 1, "connectionID": ["rawValue": id], "operation": operation(),
            ])
    }
}
