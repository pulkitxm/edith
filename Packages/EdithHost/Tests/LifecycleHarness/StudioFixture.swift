import EdithExtensionSupport
import EdithHostCore
import Foundation

extension HostLifecycleHarness {
    @MainActor static func verifyStudio(_ endpoint: ExtensionPeerEndpoint) async throws {
        try await StudioLifecycleMetadata.verify { command, input in
            try await endpoint.invoke(
                command, payload: JSONSerialization.data(withJSONObject: input), timeout: 5)
        }
    }
}

@MainActor enum InertCommandDecline {
    static func verify(
        _ commands: [String], invoke: (String) async throws -> Data
    ) async throws {
        for command in commands {
            do {
                _ = try await invoke(command)
                throw HostWorkerError.invalidResponse
            } catch ExtensionPeerError.unavailable {
            } catch let ExtensionPeerError.rejected(message) {
                guard message == ExtensionPeerError.unavailable.localizedDescription else {
                    throw HostWorkerError.invalidResponse
                }
            }
        }
    }
}

@MainActor enum StudioLifecycleMetadata {
    static func verify(
        invoke: (String, [String: Any]) async throws -> Data
    ) async throws {
        let bytes = try await invoke("studio.tools.list", [:])
        guard bytes.count <= 512 * 1_024,
            let tools = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
            !tools.isEmpty, tools.count <= 1_000
        else { throw HostWorkerError.invalidResponse }
        var ids: Set<String> = []
        for tool in tools {
            guard let id = tool["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                ids.insert(id).inserted, let title = tool["title"] as? String,
                !title.isEmpty, title.utf8.count <= 512,
                tool["family"] is String, tool["inputs"] is [String],
                tool["options"] is [[String: Any]], tool["requirements"] is [String]
            else { throw HostWorkerError.invalidResponse }
        }
        for id in ["image.resize", "pdf.to-text"] {
            guard let expected = tools.first(where: { $0["id"] as? String == id }) else {
                throw HostWorkerError.invalidResponse
            }
            let bytes = try await invoke("studio.tools.schema", ["toolID": id])
            guard bytes.count <= 512 * 1_024,
                let schema = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                NSDictionary(dictionary: schema).isEqual(to: expected)
            else { throw HostWorkerError.invalidResponse }
        }
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability("studio")))
        guard
            let input = try JSONSerialization.jsonObject(
                with: request.encoded(providerID: "studio")) as? [String: Any]
        else { throw HostWorkerError.invalidResponse }
        let snapshot = try SurfaceSnapshot.decode(
            await invoke("surface.snapshot", input), providerID: "studio")
        guard snapshot.rows.isEmpty, snapshot.metrics.count == 3,
            Set(snapshot.metrics.map(\.id)) == ["files", "projects", "running"],
            snapshot.metrics.allSatisfy({ $0.value == "0" }), snapshot.controlActions.isEmpty
        else {
            throw HostWorkerError.invalidResponse
        }
        try await InertCommandDecline.verify([
            "studio.tools.run", "studio.library.list", "studio.library.add",
            "studio.edit.create", "studio.edit.apply", "studio.edit.render",
            "studio.edit.frame", "studio.ui.record.start", "studio.ui.media.read",
            "studio.ui.video.read", "studio.cli", "surface.perform",
        ]) { command in try await invoke(command, [:]) }
    }
}
