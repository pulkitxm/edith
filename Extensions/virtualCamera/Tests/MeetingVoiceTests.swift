import AVFoundation
import Foundation
import Testing

@testable import VirtualCameraExtension

@Suite(.serialized)
struct MeetingVoiceTests {
    private static var hasModels: Bool {
        ProcessInfo.processInfo.environment["EDITH_TEST_VOICE_ENCODER"] != nil
            && ProcessInfo.processInfo.environment["EDITH_TEST_VOICE_MODEL"] != nil
    }

    @Test func invalidImportLeavesTheLibraryUnchanged() throws {
        let before = try? FileManager.default.contentsOfDirectory(
            atPath: MeetingVoiceLibrary.directory.path)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "invalid-\(UUID()).onnx")
        try Data("invalid model".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) {
            try MeetingVoiceLibrary.importing(name: "Invalid", encoder: file.path, voice: file.path)
        }
        #expect(throws: (any Error).self) {
            try MeetingVoiceLibrary.importing(name: " ", encoder: file.path, voice: file.path)
        }
        let after = try? FileManager.default.contentsOfDirectory(
            atPath: MeetingVoiceLibrary.directory.path)
        #expect((before ?? []).sorted() == (after ?? []).sorted())
    }

    @Test(.enabled(if: hasModels))
    func convertsRealModelsAndOwnsTheImportedFiles() async throws {
        let environment = ProcessInfo.processInfo.environment
        let encoder = try #require(environment["EDITH_TEST_VOICE_ENCODER"])
        let voice = try #require(environment["EDITH_TEST_VOICE_MODEL"])
        let mixer = MeetingAudioMixer()
        defer { mixer.shutdown() }
        var state = try await mixer.perform(
            .importVoice(name: "Test voice", encoder: encoder, voice: voice),
            state: MeetingAudioState())
        let model = try #require(state.voiceModels.first)
        defer {
            try? FileManager.default.removeItem(
                atPath: URL(fileURLWithPath: model.voicePath).deletingLastPathComponent().path)
        }
        #expect(model.encoderPath != encoder)
        #expect(model.voicePath != voice)
        let inference = try MeetingVoiceInference(model: model)
        var input = [Float](repeating: 0, count: 10240)
        let step = Double.pi * 240 / 16000
        for index in input.indices { input[index] = Float(0.1 * sin(Double(index) * step)) }
        let output = try inference.convert(input)
        #expect([32000, 40000, 48000].contains(output.rate))
        #expect(output.samples.count > output.rate / 2)
        let energy =
            output.samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(output.samples.count)
        #expect(energy > 0.00000001)
        #expect(energy < 0.2)
        #expect(output.samples.allSatisfy { $0.isFinite })
        #expect(throws: (any Error).self) { try inference.convert([.nan]) }
        #expect(throws: (any Error).self) { try inference.convert(input, transpose: .infinity) }
        #expect(throws: (any Error).self) { try inference.convert([0]) }
        state = try await mixer.perform(.selectVoice(model.name), state: state)
        state = try await mixer.perform(.modelPitch(-3), state: state)
        #expect(state.voiceTranspose == -3)
        await #expect(throws: (any Error).self) {
            try await mixer.perform(.modelPitch(.nan), state: state)
        }
        await #expect(throws: (any Error).self) {
            try await mixer.perform(.modelPitch(25), state: state)
        }
        let saved = try JSONDecoder().decode(
            MeetingAudioState.self, from: JSONEncoder().encode(state))
        #expect(saved == state)
        state = try await mixer.perform(.removeVoice(model.id.uuidString), state: state)
        #expect(state.voiceModels.isEmpty)
        #expect(state.voiceModelID == nil)
    }

    @Test(.enabled(if: hasModels))
    func streamingConversionRendersIntoTheMeetingFormat() async throws {
        let environment = ProcessInfo.processInfo.environment
        let model = MeetingVoiceModel(
            name: "Test voice", encoderPath: try #require(environment["EDITH_TEST_VOICE_ENCODER"]),
            voicePath: try #require(environment["EDITH_TEST_VOICE_MODEL"]))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let inputFormat = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let failure = Failure()
        let stream = try MeetingVoiceStream(
            model: model, input: inputFormat, player: player, transpose: 0,
            failure: { failure.set($0) })
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: stream.outputFormat)
        try engine.enableManualRenderingMode(.offline, format: inputFormat, maximumFrameCount: 1024)
        try engine.start()
        player.play()
        defer { stream.stop(); engine.stop() }
        for block in 0..<47 {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024))
            input.frameLength = 1024
            for index in 0..<1024 {
                let phase = Double(block * 1024 + index) * Double.pi * 240 / 48000
                for channel in 0..<2 {
                    input.floatChannelData![channel][index] = Float(0.1 * sin(phase))
                }
            }
            stream.enqueue(input)
        }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024))
        var energy = 0.0
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            if try engine.renderOffline(1024, to: output) == .success {
                for index in 0..<Int(output.frameLength) {
                    let value = Double(output.floatChannelData![0][index])
                    energy += value * value
                }
            }
        }
        #expect(failure.message == nil)
        #expect(energy > 0.001)
    }

    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        var message: String? { lock.withLock { value } }
        func set(_ message: String) { lock.withLock { value = message } }
    }
}
