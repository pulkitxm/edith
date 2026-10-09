import Foundation
import Testing
@testable import AudioMixerExtension

@Suite(.serialized) @MainActor struct AudioMixerCommandTests {
    @Test func exactBundleAndProcessBeatAmbiguousNames() throws {
        let apps = [
            AudioMixerAppRecord(
                objectID: 1, pid: 10, bundleID: "org.example.first", name: "Music", volume: 1),
            AudioMixerAppRecord(
                objectID: 2, pid: 11, bundleID: "org.example.second", name: "Music", volume: 0.4),
        ]
        #expect(try AudioMixerSelector.match("org.example.second", in: apps).pid == 11)
        #expect(try AudioMixerSelector.match("10", in: apps).pid == 10)
        #expect(throws: AudioMixerSelectionError.self) {
            try AudioMixerSelector.match("Music", in: apps)
        }
    }

    @Test func payloadValidationRejectsNonfiniteVolumeAndInvalidIdentity() {
        var raw = AudioMixerRuntimeRequest(
            request: .volume, volume: 0.4,
            deadline: Date().addingTimeInterval(1)
        ).payload
        #expect(AudioMixerRuntimeRequest(payload: raw) != nil)
        raw[AudioMixerIPC.volumeKey] = Double.nan
        #expect(AudioMixerRuntimeRequest(payload: raw) == nil)
        raw[AudioMixerIPC.volumeKey] = 0.4
        raw[AudioMixerIPC.targetKey] =
            "{\"objectID\":0,\"pid\":1,\"bundleID\":\"org.example.audio\"}"
        #expect(AudioMixerRuntimeRequest(payload: raw) == nil)
    }

    @Test func directCommandPreservesTypedFailuresAndSnapshot() throws {
        guard #available(macOS 14.4, *) else { return }
        let engine = MixerEngine(
            snapshotLoader: {
                .init(
                    apps: [
                        .init(
                            objectID: 1, pid: 10, bundleID: "org.example.audio", name: "Audio",
                            icon: nil, volume: 1)
                    ], outputUID: "synthetic")
            }, tapFactory: { _, _, _ in .failure(.deviceStart(-50)) })
        defer { engine.shutdown() }
        let result = AudioMixerAction.perform(
            .init(
                request: .volume, app: "Audio", volume: 0.4,
                deadline: Date().addingTimeInterval(1)), engine: engine)
        #expect(result.error?.contains("-50") == true)
        #expect(!result.snapshot.changed)
        #expect(result.snapshot.apps.first?.volume == 1)
        let list = AudioMixerAction.perform(
            .init(
                request: .list,
                deadline: Date().addingTimeInterval(1)), engine: engine)
        #expect(list.error == nil)
        #expect(list.snapshot.apps.count == 1)
    }
}
