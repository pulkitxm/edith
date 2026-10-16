import AppKit
import AVFoundation
import EdithExtensionSupport
import EdithStudio
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioUIMediaTests {
    @Test func engineReadsMeasuredWaveformAndTransientsAndPreservesFileBytes() async throws {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000))
        buffer.frameLength = 192000
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<192000 {
            let click = frame >= 12000 && frame < 168000 && (frame - 12000) % 24000 < 240
            let value: Float = click ? Float(sin(Double(frame) * 0.35)) * 0.8 : 0
            channels[0][frame] = value; channels[1][frame] = -value
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let original = try Data(contentsOf: url)
        let resources = StudioUIResources(); let work = StudioUILongOperations()
        let facade = StudioUIFacade { operation, payload in
            if operation.hasPrefix("studio.ui.blob.") {
                return try resources.invoke(operation, payload: payload)
            }
            if operation.hasPrefix("studio.ui.work.") {
                return try work.invoke(operation, payload: payload)
            }
            return try await StudioUIMediaCommands.execute(
                operation, payload: payload, resources: resources, work: work)
        }
        let waveform: VideoAudioEnvelope = try await facade.perform(
            "studio.ui.media.waveform", object: ["path": url.path])
        #expect(waveform.duration == 4 && waveform.peaks.contains { $0 > 0.1 })
        let beats: VideoBeatAnalysis.Result = try await facade.perform(
            "studio.ui.media.beats",
            object: ["path": url.path, "settings": try facade.object(VideoBeatAnalysis.Settings())])
        #expect(beats.transients.count == 7 && abs(beats.duration - 4) < 0.1)
        #expect(try await facade.readFile(url) == original)
        let output = root.appendingPathComponent("subtitles.srt")
        let subtitle = Data("1\n00:00:00,000 --> 00:00:01,000\nSynthetic\n".utf8)
        try await facade.writeFile(subtitle, to: output)
        #expect(try Data(contentsOf: output) == subtitle && Data(contentsOf: url) == original)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        await #expect(throws: StudioCommands.Failure.self) {
            let _: Double = try await facade.read(
                "studio.ui.media.duration", object: ["path": "relative.caf"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before)
        await work.stopAndWait(); resources.shutdown(); facade.stop()
    }

    @Test func originalRecorderStatusIsEngineOwnedAndForeignCloseCannotCapture() async throws {
        guard #available(macOS 15.0, *) else { return }
        let commands = StudioUIRecorderCommands(); let work = StudioUILongOperations()
        let id = UUID()
        let payload = try JSONSerialization.data(withJSONObject: ["id": id.uuidString])
        let data = try await commands.execute(
            "studio.ui.record.status", payload: payload, work: work)
        let state = try JSONDecoder().decode(StudioUIRecordingState.self, from: data)
        #expect(!state.snapshot.recording && !state.owned && state.startedAt == nil)
        _ = try await commands.execute("studio.ui.record.close", payload: payload, work: work)
        let invalid = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "microphone": true,
        ])
        await #expect(throws: ExtensionPeerError.self) {
            try await commands.execute("studio.ui.record.status", payload: invalid, work: work)
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await commands.execute("studio.ui.record.stop", payload: payload, work: work)
        }
        await work.stopAndWait()
    }
}
