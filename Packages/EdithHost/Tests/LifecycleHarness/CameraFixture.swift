import AVFoundation
import EdithExtensionSupport
import EdithHostCore
import Foundation

enum CameraFixture {
    static var runsInVirtualMachine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }

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
        else { throw CameraHarnessFailure("camera check failed at CameraFixture.swift:35") }
        let tile = SurfaceSnapshotRequest(target: .notch, tile: .init(.ability("virtualCamera")))
        let surface = try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.snapshot", payload: tile.encoded(providerID: "virtualCamera")),
            providerID: "virtualCamera")
        guard surface.rows.contains(where: { $0.title == "Synthetic studio" }),
            let slider = surface.sliders?.first, slider.id == "zoom",
            abs(slider.value - 1.0 / 7) < 0.001
        else { throw CameraHarnessFailure("camera check failed at CameraFixture.swift:44") }
        let changed = try SurfaceSnapshot.decode(
            await endpoint.invoke(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: tile, actionID: slider.id, value: 0.5
                ).encoded(providerID: "virtualCamera")),
            providerID: "virtualCamera")
        guard changed.sliders?.first?.value == 0.5 else {
            throw CameraHarnessFailure("camera check failed at CameraFixture.swift:52")
        }
        _ = try await request(endpoint, ["zoom": ["_0": 2.0]])
        if !runsInVirtualMachine {
            let recording = fixture.appendingPathComponent(
                "synthetic-camera-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: recording) }
            _ = try await request(endpoint, ["pause": ["_0": "blank"]])
            _ = try await request(endpoint, ["recordStart": ["_0": recording.path]])
            try await Task.sleep(for: .milliseconds(500))
            _ = try await request(endpoint, ["recordStop": [:]])
            let video = AVURLAsset(url: recording)
            guard try await video.loadTracks(withMediaType: .video).count == 1,
                try await video.load(.duration).seconds > 0.1
            else { throw CameraHarnessFailure("camera check failed at CameraFixture.swift:65") }
            let frame = try AVAssetImageGenerator(asset: video).copyCGImage(
                at: .zero, actualTime: nil)
            guard frame.width >= 320, frame.height >= 180 else {
                throw CameraHarnessFailure("camera check failed at CameraFixture.swift:69")
            }
        }
        _ = try await request(endpoint, ["pause": ["_0": "stopped"]])
        let waiting = try await hardware(endpoint, [:])
        guard waiting["route"] as? String == "obs", waiting["live"] as? Bool == false,
            waiting["obsAvailable"] as? Bool == true,
            waiting["extensionInstalled"] as? Bool == false
        else { throw CameraHarnessFailure("camera check failed at CameraFixture.swift:77") }
        _ = try await request(endpoint, ["pause": ["_0": "blank"]])
        let watching = try await hardware(endpoint, ["watching": true])
        guard watching["live"] as? Bool == true, watching["route"] as? String == "obs" else {
            throw CameraHarnessFailure("camera check failed at CameraFixture.swift:81")
        }
        let busy = try await hardware(endpoint, ["obsRunning": true])
        guard busy["live"] as? Bool == false else {
            throw CameraHarnessFailure("camera check failed at CameraFixture.swift:84")
        }
        _ = try await hardware(endpoint, ["obsRunning": false])
        try await Task.sleep(for: .seconds(2))
        let resumed = try await hardware(endpoint, ["watching": true])
        guard resumed["live"] as? Bool == true else {
            throw CameraHarnessFailure("camera check failed at CameraFixture.swift:88")
        }
        let quit = try await hardware(endpoint, ["applicationQuit": true, "watching": false])
        guard quit["live"] as? Bool == false else {
            throw CameraHarnessFailure("camera check failed at CameraFixture.swift:90")
        }
        _ = try await request(endpoint, ["pause": ["_0": "stopped"]])
        let microphone = try await carrier(endpoint, "microphone")
        guard microphone["ownsProvider"] as? Bool == false else {
            throw CameraHarnessFailure("camera check failed at CameraFixture.swift:94")
        }
        for operation in ["activate", "deactivate"] {
            var rejected = false
            do { _ = try await carrier(endpoint, operation) } catch { rejected = true }
            guard rejected else {
                throw CameraHarnessFailure("camera check failed at CameraFixture.swift:99")
            }
        }
    }

    @MainActor private static func hardware(
        _ endpoint: ExtensionPeerEndpoint, _ values: [String: Bool]
    ) async throws -> [String: Any] {
        let data = try await endpoint.invoke(
            "camera.fixture", payload: JSONSerialization.data(withJSONObject: values))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CameraHarnessFailure("camera check failed at CameraFixture.swift:109")
        }
        return value
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
            throw CameraHarnessFailure("camera check failed at CameraFixture.swift:134")
        }
        return value
    }
}
