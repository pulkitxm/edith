import AVFoundation
import Foundation
import Testing

@testable import EdithKit

@Suite(.serialized)
struct MeetingAudioTests {
    @Test func starterSoundsContainDistinctPlayableAudio() throws {
        var signatures = Set<Int>()
        for sound in MeetingSound.allCases {
            let buffer = try sound.render()
            #expect(buffer.format.sampleRate == 48000)
            #expect(buffer.frameLength == AVAudioFrameCount(sound.duration * 48000))
            let channel = try #require(buffer.floatChannelData?[0])
            var energy = 0.0
            for frame in 0..<Int(buffer.frameLength) {
                #expect(channel[frame].isFinite)
                #expect(abs(channel[frame]) <= 0.9)
                energy += Double(channel[frame] * channel[frame])
            }
            let rms = sqrt(energy / Double(buffer.frameLength))
            #expect(rms > 0.01)
            signatures.insert(Int(energy * 1000))
            let clip = try MeetingAudioLibrary.clip(sound.identifier, in: MeetingAudioState())
            #expect(clip.id == sound.id)
            #expect(try sound.clip().id == clip.id)
            #expect(!clip.speech)
            #expect(clip.name == sound.name)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: clip.path))
            #expect(file.length == Int64(buffer.frameLength))
        }
        #expect(signatures.count == MeetingSound.allCases.count)
    }

    @Test func invalidUploadsLeaveTheLibraryUnchanged() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "invalid-\(UUID()).wav")
        try Data("This is not an audio file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let mixer = MeetingAudioMixer()
        defer { mixer.shutdown() }
        let state = MeetingAudioState()
        await #expect(throws: (any Error).self) {
            try await mixer.perform(
                .importClip(name: "Invalid", path: url.path, speech: false), state: state)
        }
        #expect(state.clips.isEmpty)
    }

    @Test func importedClipsAreOwnedTrimmedAndPersisted() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tone-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<48000 { channel[index] = 0.2 * sin(Float(index) * 2 * .pi * 440 / 48000) }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try file?.write(from: buffer)
        file = nil
        let mixer = MeetingAudioMixer()
        defer { mixer.shutdown() }
        var state = try await mixer.perform(
            .importClip(name: "Good morning", path: url.path, speech: true),
            state: MeetingAudioState())
        let clip = try #require(state.clips.first)
        defer { try? FileManager.default.removeItem(atPath: clip.path) }
        #expect(clip.path != url.path)
        #expect(FileManager.default.isReadableFile(atPath: clip.path))
        await #expect(throws: (any Error).self) {
            try await mixer.perform(
                .importClip(name: "GOOD MORNING", path: url.path, speech: true), state: state)
        }
        state = try await mixer.perform(
            .editClip(name: clip.id.uuidString, start: 0.1, end: 0.8, gain: 0.7), state: state)
        #expect(state.clips[0].start == 0.1)
        #expect(state.clips[0].end == 0.8)
        #expect(state.clips[0].gain == 0.7)
        await #expect(throws: (any Error).self) {
            try await mixer.perform(
                .editClip(name: clip.name, start: 0.9, end: 0.8, gain: 1), state: state)
        }
        let saved = try JSONDecoder().decode(
            VirtualCameraState.self, from: JSONEncoder().encode(VirtualCameraState(audio: state)))
        #expect(saved.audio == state)
        state = try await mixer.perform(.removeClip(clip.name), state: state)
        #expect(state.clips.isEmpty)
        #expect(FileManager.default.fileExists(atPath: clip.path))
    }

    @Test func rejectsInvalidGainsWithoutChangingSavedState() async throws {
        let mixer = MeetingAudioMixer()
        let state = MeetingAudioState()
        await #expect(throws: (any Error).self) {
            try await mixer.perform(.levels(mic: .nan, clips: nil, source: nil), state: state)
        }
        await #expect(throws: (any Error).self) {
            try await mixer.perform(.effects(pitch: 1201, reverb: nil, delay: nil), state: state)
        }
        #expect(state == MeetingAudioState())
    }

    @Test func nativeVoiceEffectsRenderRealAudio() throws {
        let natural = try render(.natural)
        let telephone = try render(.telephone)
        #expect(natural > 0.03)
        #expect(telephone < natural * 0.4)
    }

    private func render(_ preset: MeetingVoicePreset) throws -> Double {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let effects = MeetingVoiceEffects()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        engine.attach(player)
        var previous: AVAudioNode = player
        for node in effects.nodes {
            engine.attach(node)
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        var state = MeetingAudioState()
        state.preset = preset
        effects.apply(state)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        input.frameLength = 96000
        for channel in 0..<2 {
            for index in 0..<96000 {
                input.floatChannelData![channel][index] =
                    0.2 * sin(Float(index) * 2 * .pi * 60 / 48000)
            }
        }
        player.scheduleBuffer(input)
        try engine.start()
        player.play()
        defer { engine.stop() }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        var energy = 0.0
        var count = 0
        for block in 0..<94 {
            let status = try engine.renderOffline(1024, to: output)
            #expect(status == .success)
            if block > 20, let channel = output.floatChannelData?[0] {
                for frame in 0..<Int(output.frameLength) {
                    energy += Double(channel[frame] * channel[frame])
                    count += 1
                }
            }
        }
        return sqrt(energy / Double(max(count, 1)))
    }
}
