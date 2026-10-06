import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import EdithKit

@Suite(.serialized)
struct VirtualCameraMeetingTests {
    @Test func recordsMixedAudioAlongsideVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-av-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let pool = try #require(VirtualCameraPipeline.makePool(width: 320, height: 180))
        var raw: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &raw)
        let frame = try #require(raw)
        VirtualCameraRenderer().render(
            CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)),
            into: frame)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        pcm.frameLength = 1600
        let writer = try VirtualCameraRecorder(
            url: url, size: CGSize(width: 320, height: 180), audio: true)
        for index in 0..<30 {
            for channel in 0..<2 {
                for sample in 0..<1600 {
                    pcm.floatChannelData![channel][sample] =
                        0.2 * sin(Float(index * 1600 + sample) * 2 * .pi * 440 / 48000)
                }
            }
            try writer.append(frame, at: Double(index) / 30)
            try writer.appendAudio(pcm, at: Double(index) / 30)
            try await Task.sleep(for: .milliseconds(33))
        }
        _ = try await withCheckedThrowingContinuation { continuation in
            writer.finish { continuation.resume(with: $0) }
        }
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let audio = try AVAudioFile(forReading: url)
        #expect(Double(audio.length) / audio.processingFormat.sampleRate > 0.8)
        let decoded = try #require(
            AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4800))
        try audio.read(into: decoded)
        let channel = try #require(decoded.floatChannelData?[0])
        let rms = sqrt(
            (0..<Int(decoded.frameLength)).reduce(0.0) { $0 + Double(channel[$1] * channel[$1]) }
                / Double(decoded.frameLength))
        #expect(rms > 0.05)
    }

    @Test func recordsAPlayableComposedVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 320, height: 180)
        let pool = try #require(VirtualCameraPipeline.makePool(width: 320, height: 180))
        var raw: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &raw)
        let frame = try #require(raw)
        VirtualCameraRenderer().render(
            CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.7)).cropped(
                to: CGRect(origin: .zero, size: size)), into: frame)
        let recorder = try VirtualCameraRecorder(url: url, size: size)
        for index in 0..<30 { try recorder.append(frame, at: Double(index) / 30) }
        let saved: URL = try await withCheckedThrowingContinuation { continuation in
            recorder.finish { continuation.resume(with: $0) }
        }
        #expect(saved == url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0)
        let queue = DispatchQueue(label: "test.meeting.playback")
        let source = VirtualCameraVideoSource(queue: queue)
        let received = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var settled = false
            queue.async {
                source.update(
                    VirtualCameraMedia(kind: .video, path: url.path), frameRate: 30,
                    failed: { _ in
                        lock.withLock {
                            if !settled { settled = true; continuation.resume(returning: false) }
                        }
                    }
                ) { _ in
                    lock.withLock {
                        if !settled { settled = true; continuation.resume(returning: true) }
                    }
                }
            }
            queue.asyncAfter(deadline: .now() + 5) {
                source.stop()
                lock.withLock {
                    if !settled { settled = true; continuation.resume(returning: false) }
                }
            }
        }
        #expect(received)
    }

    @Test func sourceAndPlaybackSurviveStatePersistence() throws {
        var state = VirtualCameraState()
        let media = VirtualCameraMedia(
            kind: .video, path: "/tmp/demo.mp4", playback: .paused, loop: false)
        try VirtualCameraRequestReducer.apply(
            .media(media), to: &state, sources: [], fileExists: { _ in true })
        let decoded = try JSONDecoder().decode(
            VirtualCameraState.self, from: JSONEncoder().encode(state))
        #expect(decoded.media == media)
        #expect(decoded.privacy == .live)
        try VirtualCameraRequestReducer.apply(.playback(.playing), to: &state, sources: [])
        #expect(state.media.playback == .playing)
    }

    @Test func invalidVideoLeavesTheSourceUnchanged() throws {
        var state = VirtualCameraState()
        let initial = state
        #expect(throws: VirtualCameraRequestError.missingFile("/missing.mp4")) {
            try VirtualCameraRequestReducer.apply(
                .media(VirtualCameraMedia(kind: .video, path: "/missing.mp4")),
                to: &state, sources: [], fileExists: { _ in false })
        }
        #expect(state == initial)
    }

    @Test func choosingACameraRestoresLiveCapture() throws {
        var state = VirtualCameraState(
            privacy: .freeze, media: VirtualCameraMedia(kind: .video, path: "/tmp/demo.mp4"))
        let source = VirtualCameraSource(id: "demo", name: "Demo camera", kind: .external)
        try VirtualCameraRequestReducer.apply(.selectSource("demo"), to: &state, sources: [source])
        #expect(state.media.kind == .camera)
        #expect(state.sourceID == "demo")
        #expect(state.privacy == .live)
    }

    @Test(arguments: [VirtualCameraPrivacy.card, .freeze])
    func outputOrientationCanChangeWhileAwayOrFrozen(privacy: VirtualCameraPrivacy) throws {
        var state = VirtualCameraState()
        let pipeline = VirtualCameraPipeline(
            state: state, outputSize: CGSize(width: 320, height: 180))
        let input = try #require(VirtualCameraFixtures.quadrants())
        _ = try #require(pipeline.process(input, at: 1))
        state.privacy = privacy
        state.privacyMessage = "Back in five"
        pipeline.update(state: state)
        let plain = try #require(pipeline.privacyFrame())
        state.mirrorOutput = true
        pipeline.update(state: state)
        let flipped = try #require(pipeline.privacyFrame())
        #expect(flipped !== plain)
        state.mirrorOutput = false
        pipeline.update(state: state)
        let restored = try #require(pipeline.privacyFrame())
        for y in stride(from: 10, to: 175, by: 5) {
            for x in stride(from: 10, to: 310, by: 5) {
                let a = VirtualCameraFixtures.pixel(plain, x: x, y: y)
                let b = VirtualCameraFixtures.pixel(flipped, x: 319 - x, y: y)
                let c = VirtualCameraFixtures.pixel(restored, x: x, y: y)
                #expect(
                    abs(a.red - b.red) <= 2 && abs(a.green - b.green) <= 2
                        && abs(a.blue - b.blue) <= 2)
                #expect(
                    abs(a.red - c.red) <= 2 && abs(a.green - c.green) <= 2
                        && abs(a.blue - c.blue) <= 2)
            }
        }
    }

    @Test func outputMirroringIncludesTheOverlay() throws {
        let size = CGSize(width: 320, height: 180)
        var composition = VirtualCameraComposition()
        composition.overlays.nameTag = VirtualCameraNameTag(enabled: true, title: "Meeting demo")
        let state = VirtualCameraState(composition: composition)
        var mirrored = state
        mirrored.mirrorOutput = true
        let pool = try #require(VirtualCameraPipeline.makePool(width: 320, height: 180))
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        let input = try #require(buffer)
        let renderer = VirtualCameraRenderer()
        renderer.render(
            CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(
                to: CGRect(origin: .zero, size: size)), into: input)
        let plainPipeline = VirtualCameraPipeline(state: state, outputSize: size)
        let mirrorPipeline = VirtualCameraPipeline(state: mirrored, outputSize: size)
        let plain = try #require(plainPipeline.process(input, at: 1))
        let flipped = try #require(mirrorPipeline.process(input, at: 1))
        CVPixelBufferLockBaseAddress(plain, .readOnly)
        CVPixelBufferLockBaseAddress(flipped, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(plain, .readOnly)
            CVPixelBufferUnlockBaseAddress(flipped, .readOnly)
        }
        let a = try #require(CVPixelBufferGetBaseAddress(plain)).assumingMemoryBound(to: UInt8.self)
        let b = try #require(CVPixelBufferGetBaseAddress(flipped)).assumingMemoryBound(
            to: UInt8.self)
        for y in stride(from: 120, to: 175, by: 3) {
            for x in stride(from: 10, to: 150, by: 3) {
                let left = y * CVPixelBufferGetBytesPerRow(plain) + x * 4
                let right = y * CVPixelBufferGetBytesPerRow(flipped) + (319 - x) * 4
                #expect(abs(Int(a[left]) - Int(b[right])) <= 2)
            }
        }
    }
}
