import AVFoundation
import AppKit
import CoreVideo
import Testing
@testable import Edith

@Suite struct VideoIndependentAudioTests {
    @Test func outputAudioDoesNotFollowVideoSpeedTrimOrReorder() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/first.mov"), duration: 4, width: 64, height: 64)
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/second.mov"), duration: 4, width: 64, height: 64)
        project.addAudio(URL(fileURLWithPath: "/synthetic/music.caf"), duration: 8, at: 500)
        let original = try JSONSerialization.data(
            withJSONObject: project.audioTracks.map(\.raw), options: .sortedKeys)
        var clips = project.clips
        clips[0].rate = 2
        clips[1].rate = 0.5
        project.setClips(clips)
        project.addTrim(clipID: clips[0].id, start: 1, end: 2)
        project.setClips(Array(project.clips.reversed()))
        project.split(clipID: clips[1].id, at: 2)
        let after = try JSONSerialization.data(
            withJSONObject: project.audioTracks.map(\.raw), options: .sortedKeys)
        #expect(original == after)
        #expect(project.audioTracks.count == 1)
        #expect(project.audioTracks[0].startMs == 500)
    }

    @Test func exportedMusicRemainsContinuousAcrossSpeedChangesAndCuts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("silent.mov")
        let music = directory.appendingPathComponent("music.caf")
        try await createVideo(video, duration: 4)
        try createAudio(music, duration: 4) { time in
            Float(sin(time * 2 * .pi * 440)) * (time < 1 ? 0.12 : time < 2 ? 0.32 : 0.6)
        }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        project.addAudio(music, duration: 4, at: 0)
        project.split(clipID: project.clips[0].id, at: 2)
        var clips = project.clips
        clips[0].rate = 2
        project.setClips(clips)
        project.addTrim(clipID: clips[1].id, start: 2.5, end: 3)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(abs(pipeline.duration - 2.5) < 0.001)
        let audio = try #require(pipeline.composition.tracks(withMediaType: .audio).first)
        let mappings = audio.segments.filter { !$0.isEmpty }
        #expect(mappings.count == 1)
        #expect(abs(mappings[0].timeMapping.source.duration.seconds - 2.5) < 0.001)
        let exported = directory.appendingPathComponent("continuous.mp4")
        try await pipeline.exportMP4(to: exported)
        let samples = try await readAudio(exported)
        #expect(abs(rms(samples, from: 0.2, to: 0.8) - 0.12 / sqrt(2)) < 0.025)
        #expect(abs(rms(samples, from: 1.2, to: 1.8) - 0.32 / sqrt(2)) < 0.025)
        #expect(abs(rms(samples, from: 2.1, to: 2.4) - 0.6 / sqrt(2)) < 0.025)
    }

    @Test func exportedSourceGainMuteAndRangesAreAppliedAtOutputTime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("source.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 4) { Float(sin($0 * 2 * .pi * 440)) * 0.5 }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        var assets = project.assets.map(\.raw)
        assets[0]["edithAudioPath"] = sound.path
        project.root["assets"] = assets
        project.split(clipID: project.clips[0].id, at: 3)
        var clips = project.clips
        clips[0].rate = 2
        clips[0].raw["audioGainDb"] = -6.0206
        clips[1].raw["audioMuted"] = true
        project.setClips(clips)
        var timeline = project.root["timeline"] as? [String: Any] ?? [:]
        timeline["muteRanges"] = [
            [
                "clipId": clips[0].id, "assetId": clips[0].assetID, "startSec": 1.0, "endSec": 2.0,
            ]
        ]
        project.root["timeline"] = timeline
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let exported = directory.appendingPathComponent("source-mix.mp4")
        try await pipeline.exportMP4(to: exported)
        let samples = try await readAudio(exported)
        #expect(abs(rms(samples, from: 0.1, to: 0.4) - 0.25 / sqrt(2)) < 0.03)
        #expect(rms(samples, from: 0.6, to: 0.9) < 0.003)
        #expect(rms(samples, from: 1.1, to: 1.4) > 0.14)
        #expect(rms(samples, from: 1.7, to: 2.3) < 0.003)
    }

    @Test func exportedMusicTrimsLoopsAndFadesInOutputSeconds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sound = directory.appendingPathComponent("short.caf")
        try await createVideo(video, duration: 4)
        try createAudio(sound, duration: 1) { Float(sin($0 * 2 * .pi * 440)) * 0.5 }
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 64, height: 64)
        project.addAudio(sound, duration: 1, at: 0)
        let id = try #require(project.audioTracks.first?.id)
        project.setAudioOptions(id, loop: true, fadeInMs: 500, fadeOutMs: 500)
        project.retimeAudio(id, start: 0.5, end: 3.5, trimStart: true)
        project.setAudioGain(id, decibels: -6.0206)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let exported = directory.appendingPathComponent("looped.mp4")
        try await pipeline.exportMP4(to: exported)
        let samples = try await readAudio(exported)
        #expect(rms(samples, from: 0.1, to: 0.3) < 0.003)
        let normal = rms(samples, from: 1.2, to: 2.8)
        #expect(abs(normal - 0.25 / sqrt(2)) < 0.025)
        #expect(rms(samples, from: 0.55, to: 0.65) < normal * 0.4)
        #expect(rms(samples, from: 3.35, to: 3.45) < normal * 0.4)
        #expect(rms(samples, from: 3.7, to: 3.9) < 0.003)
        project.setAudioOptions(id, muted: true)
        let muted = try await VideoRenderPipeline.make(project: project)
        #expect(muted.composition.tracks(withMediaType: .audio).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audio-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createAudio(_ url: URL, duration: Double, sample: (Double) -> Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let count = AVAudioFrameCount(duration * 48000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let values = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(count) { values[index] = sample(Double(index) / 48000) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func createVideo(_ url: URL, duration: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<Int(duration * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 100, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(
                adaptor.append(
                    pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func readAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        #expect(reader.startReading())
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            #expect(status == kCMBlockBufferNoErr)
            let start = max(
                0, Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 48000).rounded()))
            if result.count < start {
                result.append(contentsOf: repeatElement(0, count: start - result.count))
            }
            result.append(contentsOf: values)
        }
        #expect(reader.status == .completed)
        return result
    }

    private func rms(_ samples: [Float], from: Double, to: Double) -> Double {
        let start = min(samples.count, Int(from * 48000))
        let end = min(samples.count, Int(to * 48000))
        guard end > start else { return 0 }
        return sqrt(samples[start..<end].reduce(0.0) { $0 + Double($1 * $1) } / Double(end - start))
    }
}
