import AVFoundation
import EdithExtensionSupport
import EdithHostCore
import Foundation

enum CameraFixture {
    @MainActor static func verify(_ endpoint: ExtensionPeerEndpoint, fixture: URL, seed: Bool)
        async throws
    {
        if seed {
            _ = try await request(endpoint, ["zoom": ["_0": 2.0]])
            _ = try await request(endpoint, ["mirrorOutput": ["_0": true]])
            _ = try await request(
                endpoint, ["saveScene": ["_0": "Synthetic studio", "replace": false]])
            _ = try await request(endpoint, ["pause": ["_0": "stopped"]])
        }
        let data = try await endpoint.invoke("camera.snapshot", payload: Data("{}".utf8))
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let state = snapshot["state"] as? [String: Any],
            let composition = state["composition"] as? [String: Any],
            let framing = composition["framing"] as? [String: Any],
            framing["zoom"] as? Double == 2,
            state["mirrorOutput"] as? Bool == true,
            state["privacy"] as? String == "stopped",
            let scenes = state["scenes"] as? [[String: Any]],
            scenes.contains(where: { $0["name"] as? String == "Synthetic studio" }),
            snapshot["live"] as? Bool == false,
            (snapshot["sources"] as? [Any])?.isEmpty == true
        else { throw HostWorkerError.invalidResponse }
        let tile = SurfaceSnapshotRequest(target: .notch, tile: .init(.ability("virtualCamera")))
        let surface = try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.snapshot", payload: tile.encoded(providerID: "virtualCamera")),
            providerID: "virtualCamera")
        guard surface.rows.contains(where: { $0.title == "Synthetic studio" }),
            let slider = surface.sliders?.first, slider.id == "zoom",
            abs(slider.value - 1.0 / 7) < 0.001
        else { throw HostWorkerError.invalidResponse }
        let changed = try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: tile, actionID: slider.id, value: 0.5
                ).encoded(providerID: "virtualCamera")),
            providerID: "virtualCamera")
        guard changed.sliders?.first?.value == 0.5 else { throw HostWorkerError.invalidResponse }
        _ = try await request(endpoint, ["zoom": ["_0": 2.0]])
        let recording = fixture.appendingPathComponent("synthetic-camera-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: recording) }
        _ = try await request(endpoint, ["pause": ["_0": "blank"]])
        _ = try await request(endpoint, ["recordStart": ["_0": recording.path]])
        try await Task.sleep(for: .milliseconds(500))
        _ = try await request(endpoint, ["recordStop": [:]])
        let video = AVURLAsset(url: recording)
        guard try await video.loadTracks(withMediaType: .video).count == 1,
            try await video.load(.duration).seconds > 0.1
        else { throw HostWorkerError.invalidResponse }
        let frame = try AVAssetImageGenerator(asset: video).copyCGImage(at: .zero, actualTime: nil)
        guard frame.width >= 320, frame.height >= 180 else { throw HostWorkerError.invalidResponse }
        _ = try await request(endpoint, ["pause": ["_0": "stopped"]])
        let active = try await carrier(endpoint, "activate")
        guard active["phase"] as? String == "active", active["ownsProvider"] as? Bool == true
        else { throw HostWorkerError.invalidResponse }
        _ = try await carrier(endpoint, "microphone")
        let stopped = try await carrier(endpoint, "deactivate")
        guard stopped["phase"] as? String == "stopped", stopped["ownsProvider"] as? Bool == false
        else { throw HostWorkerError.invalidResponse }
    }

    @MainActor private static func request(
        _ endpoint: ExtensionPeerEndpoint, _ value: [String: Any]
    ) async throws -> Data {
        let encoded = String(
            decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        return try await endpoint.invoke(
            "camera.request",
            payload: JSONSerialization.data(withJSONObject: [
                "request": encoded, "requestID": UUID().uuidString,
                "deadline": Date().addingTimeInterval(30).timeIntervalSince1970,
            ]))
    }

    @MainActor private static func carrier(_ endpoint: ExtensionPeerEndpoint, _ operation: String)
        async throws -> [String: Any]
    {
        let data = try await endpoint.invoke(
            "camera.extension",
            payload: JSONSerialization.data(withJSONObject: ["operation": operation]))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostWorkerError.invalidResponse
        }
        return value
    }
}
