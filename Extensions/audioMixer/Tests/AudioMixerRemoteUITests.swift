import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import AudioMixerExtension

@Suite(.serialized) @MainActor struct AudioMixerRemoteUITests {
    @Test func originalPaneUsesOwningEngineAndShowsTapFailureWithoutChangingVolume() async throws {
        guard #available(macOS 14.4, *) else { return }
        let engine = MixerEngine(
            snapshotLoader: {
                .init(
                    apps: [
                        .init(
                            objectID: 1, pid: 424242, bundleID: "synthetic.audio",
                            name: "Synthetic Audio", icon: nil, volume: 1)
                    ], outputUID: "synthetic")
            }, tapFactory: { _, _, _ in .failure(.deviceStart(-50)) })
        let bridge = Bridge(engine: engine)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let remote = AudioMixerRemoteModel(client: client)
        remote.viewAppeared()
        try await wait { remote.apps.count == 1 }
        #expect(remote.apps.first?.name == "Synthetic Audio" && remote.apps.first?.volume == 1)
        remote.setVolume(try #require(remote.apps.first), 0.4)
        try await wait { remote.errorMessage != nil }
        #expect(engine.apps.first?.volume == 1 && remote.apps.first?.volume == 1)
        remote.stop(); client.invalidate(); engine.shutdown()
        let count = bridge.operations.count
        remote.retry(); remote.viewAppeared()
        await Task.yield()
        #expect(bridge.operations.count == count)
    }
    @Test func originalRowsRenderOffscreenAtCompactRegularAndIncreasedZoom() throws {
        guard #available(macOS 14.4, *) else { return }
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let engine = MixerEngine(
            snapshotLoader: {
                .init(
                    apps: [
                        .init(
                            objectID: 1, pid: 424242, bundleID: "synthetic.audio",
                            name: "Synthetic Audio", icon: nil, volume: 1)
                    ], outputUID: "synthetic")
            }, tapFactory: { _, _, _ in .failure(.deviceStart(-50)) })
        defer { engine.shutdown(); UIScale.apply(1) }
        for width in [360, 900] {
            for scheme in [ColorScheme.light, .dark] {
                UIScale.apply(1.4)
                let view = NSHostingView(
                    rootView: AudioMixerView(engine: engine, monitorsWhileVisible: false)
                        .environment(\.compactLayout, width < 720).environment(
                            \.colorScheme, scheme))
                view.frame = NSRect(x: 0, y: 0, width: width, height: 240)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                #expect(
                    bitmap.pixelsWide >= width && bitmap.pixelsHigh >= 240
                        && bitmap.tiffRepresentation?.isEmpty == false)
            }
        }
        #expect(app.windows.allSatisfy { !$0.isVisible })
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExtensionEngineError.timedOut };
            await Task.yield()
        }
    }
    @available(macOS 14.4, *) @MainActor private final class Bridge: NSObject {
        let engine: MixerEngine
        let registry = ExtensionCommandRegistry()
        var operations: [String] = []
        init(engine: MixerEngine) { self.engine = engine }
        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            operations.append(request.operation)
            registry.invoke(
                [
                    "token": request.token.uuidString, "command": request.operation,
                    "payload": request.payload,
                ],
                completion: { bytes, error in
                    completion(
                        (try? ExtensionEngineWire.encode(
                            ExtensionEngineReply(
                                token: request.token, ok: error == nil && bytes != nil,
                                payload: bytes as Data? ?? Data("{}".utf8)))) ?? Data())
                },
                execute: { [engine] operation, payload in
                    if operation == "audioMixer.ui.snapshot" {
                        engine.refresh()
                        return try JSONEncoder().encode(
                            AudioMixerUISnapshot(
                                apps: engine.apps.map {
                                    .init(
                                        objectID: $0.objectID, pid: $0.pid, bundleID: $0.bundleID,
                                        name: $0.name, volume: Double($0.volume))
                                }, icons: [:], error: engine.errorMessage))
                    }
                    guard operation == "audioMixer.request",
                        let values = try JSONSerialization.jsonObject(with: payload)
                            as? [String: Any],
                        let request = AudioMixerRuntimeRequest(payload: values)
                    else { throw ExtensionPeerError.invalidRequest }
                    let result = AudioMixerAction.perform(request, engine: engine)
                    if let error = result.error { throw ExtensionPeerError.rejected(error) }
                    return try JSONEncoder().encode(result.snapshot)
                })
        }
        @objc func cancel(_ token: String) { registry.cancel(token) }
    }
}
