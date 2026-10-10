import EdithExtensionSupport
import EdithHostCore
import Foundation

enum AudioMixerFixture {
    @MainActor static func verify(_ endpoint: ExtensionPeerEndpoint) async throws {
        let request = SurfaceSnapshotRequest(target: .notch, tile: .init(.ability("audioMixer")))
        let data = try await endpoint.invoke(
            "surface.snapshot", payload: request.encoded(providerID: "audioMixer"))
        let snapshot = try SurfaceSnapshot.decode(data, providerID: "audioMixer")
        guard snapshot.rows.count == 1, snapshot.rows.first?.title == "Synthetic audio",
            let slider = snapshot.rows.first?.sliders?.first, slider.value == 1,
            snapshot.metrics.first(where: { $0.id == "apps" })?.value == "1"
        else { throw HostWorkerError.invalidResponse }
        let adjusted = try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: request, actionID: slider.id, value: 0.5
            ).encoded(providerID: "audioMixer"))
        let changed = try SurfaceSnapshot.decode(adjusted, providerID: "audioMixer")
        guard changed.rows.first?.sliders?.first?.value == 0.5,
            let mute = changed.rows.first?.actions.first
        else { throw HostWorkerError.invalidResponse }
        let muted = try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: request, actionID: mute.id
            ).encoded(providerID: "audioMixer"))
        let silent = try SurfaceSnapshot.decode(muted, providerID: "audioMixer")
        guard silent.rows.first?.sliders?.first?.value == 0,
            silent.metrics.first(where: { $0.id == "muted" })?.value == "1",
            let restore = silent.rows.first?.actions.first
        else { throw HostWorkerError.invalidResponse }
        let restored = try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: request, actionID: restore.id
            ).encoded(providerID: "audioMixer"))
        guard
            try SurfaceSnapshot.decode(restored, providerID: "audioMixer").rows.first?.sliders?
                .first?.value == 1
        else { throw HostWorkerError.invalidResponse }
    }
}
