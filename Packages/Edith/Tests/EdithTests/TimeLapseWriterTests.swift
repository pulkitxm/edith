import AVFoundation
import CoreImage
import EdithCore
import Testing

@testable import Edith

@Suite(.serialized) struct TimeLapseWriterTests {
    @Test func segmentsRollOverAndOriginalExportPreservesTiming() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = TimeLapseSettings()
        settings.interval = 1
        settings.maximumDimension = 1920
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: settings, width: 128, height: 64), sourceCount: 2,
            failure: { _ in }, progress: { _, _ in })
        let red = try buffer(color: .red)
        let blue = try buffer(color: .blue)
        let uptime = ProcessInfo.processInfo.systemUptime
        for index in 0..<301 {
            await withCheckedContinuation { continuation in
                writer.queue.async {
                    writer.setFrame(red, source: 0)
                    writer.setFrame(blue, source: 1)
                    writer.capture(at: uptime + Double(index))
                    continuation.resume()
                }
            }
            if index % 10 == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        let session = await writer.stop()
        #expect(session.failure == nil)
        #expect(session.frames == 301)
        #expect(session.segments.count == 2)
        #expect(session.segments[0].frames == 300)
        let loaded = try TimeLapseRecording.load(in: directory.deletingLastPathComponent())
        #expect(loaded.contains { $0.id == session.id })
        let recording = TimeLapseRecording(session: session, directory: directory)
        let composition = try await TimeLapseExporter.composition(recording)
        #expect(abs(composition.duration.seconds - 301.0 / 30) < 0.002)
        let unmarkedDirectory = URL(fileURLWithPath: directory.path, isDirectory: false)
        let unmarked = try await TimeLapseExporter.composition(
            .init(session: session, directory: unmarkedDirectory))
        #expect(abs(unmarked.duration.seconds - composition.duration.seconds) < 0.002)
        let asset = AVURLAsset(url: directory.appendingPathComponent(session.segments[0].file))
        let image = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
        let pixels = CIImage(cgImage: image)
        let context = CIContext()
        var first: [UInt8] = [0, 0, 0, 0]
        var second: [UInt8] = [0, 0, 0, 0]
        context.render(
            pixels, toBitmap: &first, rowBytes: 4,
            bounds: CGRect(x: 16, y: 32, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        context.render(
            pixels, toBitmap: &second, rowBytes: 4,
            bounds: CGRect(x: 96, y: 32, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(first[0] > 200 && first[2] < 40)
        #expect(second[2] > 200 && second[0] < 40)
        if #available(macOS 15.0, *) {
            for quality in [TimeLapseExportQuality.original, .compact, .high, .editing] {
                let destination = directory.appendingPathComponent(
                    "export-\(quality.id.hashValue).\(quality.fileExtension)")
                try await TimeLapseExporter.export(recording, quality: quality, to: destination)
                let duration = try await AVURLAsset(url: destination).load(.duration)
                #expect(abs(duration.seconds - 301.0 / 30) < 0.002)
            }
        }
    }

    @Test func allSourcesMustBePresentAndIdleFramesCanRepeat() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: TimeLapseSettings(), width: 128, height: 64),
            sourceCount: 2, failure: { _ in }, progress: { _, _ in })
        let image = try buffer(color: .green)
        let uptime = ProcessInfo.processInfo.systemUptime
        await withCheckedContinuation { continuation in
            writer.queue.async {
                writer.setFrame(image, source: 0)
                writer.capture(at: uptime)
                writer.setFrame(image, source: 1)
                writer.capture(at: uptime + 5)
                continuation.resume()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await withCheckedContinuation { continuation in
            writer.queue.async {
                writer.capture(at: uptime + 10); continuation.resume()
            }
        }
        let session = await writer.stop()
        #expect(session.frames == 2)
    }

    @Test func emptyAndLowDiskSessionsStopCleanly() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = TimeLapseSession(settings: TimeLapseSettings(), width: 64, height: 64)
        #expect(throws: TimeLapseError.self) {
            try TimeLapseWriter(
                directory: directory, session: session, sourceCount: 1,
                availableBytes: { _ in 100 }, failure: { _ in }, progress: { _, _ in })
        }
        let writer = try TimeLapseWriter(
            directory: directory, session: session, sourceCount: 1,
            failure: { _ in }, progress: { _, _ in })
        let stopped = await writer.stop()
        #expect(stopped.failure == TimeLapseError.empty.localizedDescription)
        #expect(stopped.segments.isEmpty)
    }

    @Test func interruptedLibraryKeepsFinalizedSegments() throws {
        let root = temporaryDirectory()
        let directory = root.appendingPathComponent("session")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var session = TimeLapseSession(settings: TimeLapseSettings(), width: 64, height: 64)
        session.segments = [
            .init(
                file: "video-000000.mov", kind: "video", frames: 300,
                startedAt: Date(), duration: 10)
        ]
        try JSONEncoder().encode(session).write(
            to: directory.appendingPathComponent("session.json"))
        let recordings = try TimeLapseRecording.load(in: root)
        #expect(recordings.count == 1)
        #expect(recordings[0].session.endedAt == nil)
        #expect(recordings[0].session.frames == 300)
    }

    @Test func missingMediaFailsWithoutReplacingAnExistingExport() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var session = TimeLapseSession(settings: TimeLapseSettings(), width: 64, height: 64)
        session.segments = [
            .init(
                file: "missing.mov", kind: "video", frames: 1,
                startedAt: Date(), duration: 1.0 / 30)
        ]
        let destination = directory.appendingPathComponent("existing.mp4")
        let original = Data("synthetic existing file".utf8)
        try original.write(to: destination)
        if #available(macOS 15.0, *) {
            await #expect(throws: (any Error).self) {
                try await TimeLapseExporter.export(
                    .init(session: session, directory: directory),
                    quality: .original, to: destination)
            }
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test func audioTracksRetainNormalSpeedAndExportSeparately() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = TimeLapseSettings()
        settings.systemAudio = true
        settings.microphoneID = "synthetic-microphone"
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: settings, width: 64, height: 64),
            sourceCount: 1, failure: { _ in }, progress: { _, _ in })
        for index in 0..<10 {
            let sample = try audioSample(at: 100 + Double(index) / 10)
            await withCheckedContinuation { continuation in
                writer.queue.async {
                    writer.ingest(sample, source: 0, kind: "system")
                    writer.ingest(sample, source: 0, kind: "microphone")
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let session = await writer.stop()
        #expect(session.segments.filter { $0.kind == "system" }.count == 1)
        #expect(session.segments.filter { $0.kind == "microphone" }.count == 1)
        if #available(macOS 15.0, *) {
            for kind in ["system", "microphone"] {
                let destination = directory.appendingPathComponent("\(kind).m4a")
                try await TimeLapseExporter.export(
                    .init(session: session, directory: directory),
                    quality: .original, to: destination, kind: kind)
                let asset = AVURLAsset(url: destination)
                let duration = try await asset.load(.duration)
                #expect(abs(duration.seconds - 1) < 0.1)
                #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
            }
        }
    }

    private func audioSample(at seconds: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        #expect(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil,
                blockLength: 19200, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: 19200, flags: 0, blockBufferOut: &block) == noErr)
        #expect(
            CMBlockBufferFillDataBytes(
                with: 0, blockBuffer: try #require(block),
                offsetIntoDestination: 0, dataLength: 19200) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48000),
            decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        #expect(
            CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: block,
                formatDescription: format, sampleCount: 4800, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "timelapse-\(UUID().uuidString)")
    }

    private func buffer(color: CIColor) throws -> CVPixelBuffer {
        var raw: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &raw)
        let buffer = try #require(raw)
        #expect(status == kCVReturnSuccess)
        CIContext().render(
            CIImage(color: color), to: buffer,
            bounds: CGRect(x: 0, y: 0, width: 64, height: 64),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}
