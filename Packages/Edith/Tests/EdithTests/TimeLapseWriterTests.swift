import AVFoundation
import CoreImage
import EdithCore
import Testing

@testable import Edith

@Suite(.serialized) struct TimeLapseWriterTests {
    @Test(arguments: [Int32(30), 60], [0, 1, 2])
    func standardRecordingKeepsWallTimeAndIncludesSelectedAudio(frameRate: Int32, audioCount: Int)
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = TimeLapseSettings()
        settings.frameRate = frameRate
        settings.systemAudio = audioCount > 0
        settings.microphoneID = audioCount == 2 ? "synthetic-microphone" : nil
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: settings, width: 64, height: 64), sourceCount: 1,
            failure: { _ in }, progress: { _, _, _ in })
        let image = try buffer(color: .green)
        let origin = ProcessInfo.processInfo.systemUptime
        for time in [0.0, 0.15, 0.4, 0.8] {
            let sample = try audioSample(at: origin + time + 0.1)
            await withCheckedContinuation { continuation in
                writer.queue.async {
                    writer.setFrame(image, source: 0)
                    writer.capture(at: origin + time)
                    writer.ingest(sample, source: -1, kind: "system")
                    writer.ingest(sample, source: -1, kind: "microphone")
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        let session = await writer.stop()
        #expect(session.failure == nil)
        #expect(session.frames == 4)
        let expected = 0.8 + 1 / Double(frameRate)
        #expect(abs(session.playbackSeconds - expected) < 0.002)
        let recording = TimeLapseRecording(session: session, directory: directory)
        let composition = try await TimeLapseExporter.composition(recording)
        #expect(abs(composition.duration.seconds - expected) < 0.002)
        let audio = try await composition.loadTracks(withMediaType: .audio)
        #expect(audio.count == audioCount)
        for track in audio {
            let range = try await track.load(.timeRange)
            let segments = try await track.load(.segments).filter { !$0.isEmpty }
            let first = try #require(segments.first)
            #expect(abs(first.timeMapping.target.start.seconds - 0.1) < 0.003)
            #expect(range.end.seconds <= expected + 0.003)
        }
        if #available(macOS 15.0, *) {
            for quality in TimeLapseExportQuality.allCases {
                let destination = directory.appendingPathComponent(
                    "standard-\(quality.id.hashValue).\(quality.fileExtension)")
                try await TimeLapseExporter.export(recording, quality: quality, to: destination)
                let asset = AVURLAsset(url: destination)
                #expect(abs(try await asset.load(.duration).seconds - expected) < 0.05)
                #expect(
                    try await asset.loadTracks(withMediaType: .audio).count == min(1, audioCount))
                if audioCount > 0 { #expect(try await audioHasSignal(asset)) }
                #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
            }
        }
    }

    @Test func standardSegmentsPreserveGapsAndRecoverWithinFiveMinutes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: TimeLapseSettings(), width: 64, height: 64),
            sourceCount: 1,
            failure: { _ in }, progress: { _, _, _ in })
        let image = try buffer(color: .blue)
        let origin = ProcessInfo.processInfo.systemUptime
        for time in [0.0, 299.9, 300.5] {
            await withCheckedContinuation { continuation in
                writer.queue.async {
                    writer.setFrame(image, source: 0)
                    writer.capture(at: origin + time)
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        let session = await writer.stop()
        #expect(session.failure == nil)
        #expect(session.segments.count == 2)
        #expect(session.segments.allSatisfy { $0.duration <= 300 })
        #expect(abs(session.playbackSeconds - (300.5 + 1.0 / 30)) < 0.003)
        let composition = try await TimeLapseExporter.composition(
            .init(session: session, directory: directory))
        #expect(abs(composition.duration.seconds - session.playbackSeconds) < 0.003)
    }

    @Test func segmentsRollOverAndOriginalExportPreservesTiming() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = TimeLapseSettings()
        settings.mode = .timeLapse
        settings.interval = 1
        settings.maximumDimension = 1920
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: settings, width: 128, height: 64), sourceCount: 2,
            failure: { _ in }, progress: { _, _, _ in })
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
            session: TimeLapseSession(settings: timeLapseSettings(), width: 128, height: 64),
            sourceCount: 2, failure: { _ in }, progress: { _, _, _ in })
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
        let session = TimeLapseSession(settings: timeLapseSettings(), width: 64, height: 64)
        #expect(throws: TimeLapseError.self) {
            try TimeLapseWriter(
                directory: directory, session: session, sourceCount: 1,
                availableBytes: { _ in 100 }, failure: { _ in }, progress: { _, _, _ in })
        }
        let writer = try TimeLapseWriter(
            directory: directory, session: session, sourceCount: 1,
            failure: { _ in }, progress: { _, _, _ in })
        let stopped = await writer.stop()
        #expect(stopped.failure == TimeLapseError.empty.localizedDescription)
        #expect(stopped.segments.isEmpty)
    }

    @Test func interruptedLibraryKeepsFinalizedSegments() throws {
        let root = temporaryDirectory()
        let directory = root.appendingPathComponent("session")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var session = TimeLapseSession(settings: timeLapseSettings(), width: 64, height: 64)
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
        var session = TimeLapseSession(settings: timeLapseSettings(), width: 64, height: 64)
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

    @Test(arguments: [30.0, 60, 150, 300, 900, 1800], [1, 2])
    func timeLapseExportsOneVideoWithAcceleratedAudio(speed: Double, audioCount: Int) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = timeLapseSettings()
        settings.speed = speed
        settings.systemAudio = true
        settings.microphoneID = audioCount == 2 ? "synthetic-microphone" : nil
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: settings, width: 64, height: 64),
            sourceCount: 1, failure: { _ in }, progress: { _, _, _ in })
        let image = try buffer(color: .green)
        for index in 0..<31 {
            let time = 100 + Double(index) * settings.interval
            let sample = try audioSample(at: time)
            await withCheckedContinuation { continuation in
                writer.queue.async {
                    writer.setFrame(image, source: 0)
                    writer.capture(at: time)
                    writer.ingest(sample, source: -1, kind: "system")
                    writer.ingest(sample, source: -1, kind: "microphone")
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let session = await writer.stop()
        #expect(session.failure == nil)
        #expect(session.frames == 31)
        let audioDuration = 30 * settings.interval + 0.1
        let audioStart = try #require(session.segments.first(where: { $0.kind == "video" }))
            .startedAt
        var exportedSession = session
        exportedSession.segments.removeAll { $0.kind != "video" }
        let fixture = directory.appendingPathComponent("system.wav")
        try continuousAudio(at: fixture, seconds: audioDuration)
        for kind in audioCount == 2 ? ["system", "microphone"] : ["system"] {
            let file = "\(kind).wav"
            if kind == "microphone" {
                try FileManager.default.linkItem(
                    at: fixture, to: directory.appendingPathComponent(file))
            }
            exportedSession.segments.append(
                .init(
                    file: file, kind: kind, frames: 0,
                    startedAt: audioStart, duration: audioDuration))
        }
        let recording = TimeLapseRecording(session: exportedSession, directory: directory)
        let composition = try await TimeLapseExporter.composition(recording)
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        #expect(tracks.count == audioCount)
        for track in tracks {
            let segments = try await track.load(.segments).filter { !$0.isEmpty }
            let first = try #require(segments.first)
            let mapping = first.timeMapping
            #expect(
                abs(mapping.source.duration.seconds / mapping.target.duration.seconds - speed) < 0.1
            )
            #expect(
                try await track.load(.timeRange).duration.seconds <= session.playbackSeconds + 0.01)
        }
        if #available(macOS 15.0, *) {
            for quality in TimeLapseExportQuality.allCases {
                let destination = directory.appendingPathComponent(
                    "time-lapse-\(quality.id.hashValue).\(quality.fileExtension)")
                try await TimeLapseExporter.export(recording, quality: quality, to: destination)
                let asset = AVURLAsset(url: destination)
                #expect(
                    abs(try await asset.load(.duration).seconds - session.playbackSeconds) < 0.05)
                #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
                #expect(try await audioHasSignal(asset))
                #expect(abs(try audioFrequency(at: destination) - 440) < 40)
                #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(
                !files.contains {
                    $0.hasSuffix(".m4a") || $0.hasSuffix(".caf") || $0.hasSuffix(".partial")
                })
        }
    }

    @Test(arguments: [30.0, 1800])
    func acceleratedShortAudioKeepsItsEnding(speed: Double) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = timeLapseSettings()
        settings.speed = speed
        settings.systemAudio = true
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: settings, width: 64, height: 64), sourceCount: 1,
            failure: { _ in }, progress: { _, _, _ in })
        let image = try buffer(color: .green)
        await withCheckedContinuation { continuation in
            writer.queue.async {
                writer.setFrame(image, source: 0)
                writer.capture(at: 100)
                continuation.resume()
            }
        }
        var session = await writer.stop()
        #expect(session.failure == nil)
        #expect(session.frames == 1)
        let start = try #require(session.segments.first).startedAt
        let audio = directory.appendingPathComponent("ending.wav")
        try continuousAudio(
            at: audio, seconds: settings.interval,
            activeRange: (settings.interval * 0.55)..<settings.interval)
        session.segments.append(
            .init(
                file: "ending.wav", kind: "system", frames: 0, startedAt: start,
                duration: settings.interval))
        if #available(macOS 15.0, *) {
            for quality in TimeLapseExportQuality.allCases {
                let destination = directory.appendingPathComponent(
                    "ending-\(quality.id.hashValue).\(quality.fileExtension)")
                try await TimeLapseExporter.export(
                    .init(session: session, directory: directory), quality: quality, to: destination
                )
                let asset = AVURLAsset(url: destination)
                #expect(abs(try await asset.load(.duration).seconds - 1.0 / 30) < 0.01)
                #expect(try await audioHasSignal(asset))
            }
        }
    }

    @Test(arguments: [false, true])
    func previewSkipsHiddenOrBusyConsumersAndUsesTheCapturedMosaic(delayedConsumer: Bool)
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previews = PreviewFrames()
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: timeLapseSettings(), width: 1920, height: 1080),
            sourceCount: 2, failure: { _ in }, progress: { _, _, _ in },
            preview: { image in
                if delayedConsumer { try? await Task.sleep(for: .seconds(1)) }
                previews.append(image)
            })
        let red = try buffer(color: .red)
        let blue = try buffer(color: .blue)
        let uptime = ProcessInfo.processInfo.systemUptime
        for index in 0..<3 {
            writer.setPreviewEnabled(delayedConsumer || index == 1)
            await withCheckedContinuation { continuation in
                writer.queue.async {
                    writer.setFrame(red, source: 0)
                    writer.setFrame(blue, source: 1)
                    writer.capture(at: uptime + Double(index) * 5)
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = await writer.stop()
        #expect(session.failure == nil)
        #expect(session.frames == 3)
        if delayedConsumer { try await Task.sleep(for: .milliseconds(1100)) }
        let images = previews.snapshot
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(image.width == 960 && image.height == 540)
        var left: [UInt8] = [0, 0, 0, 0]
        var right: [UInt8] = [0, 0, 0, 0]
        let context = CIContext()
        let pixels = CIImage(cgImage: image)
        context.render(
            pixels, toBitmap: &left, rowBytes: 4,
            bounds: CGRect(x: 240, y: 270, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        context.render(
            pixels, toBitmap: &right, rowBytes: 4,
            bounds: CGRect(x: 720, y: 270, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        #expect(left[0] > 200 && left[2] < 40)
        #expect(right[2] > 200 && right[0] < 40)
    }

    @Test func firstFrameArrivesWithoutWaitingForTheCaptureInterval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = TimeLapseSettings()
        settings.mode = .timeLapse
        settings.interval = 60
        let writer = try TimeLapseWriter(
            directory: directory,
            session: TimeLapseSession(settings: settings, width: 64, height: 64),
            sourceCount: 1, failure: { _ in }, progress: { _, _, _ in })
        writer.startTimer()
        let image = try buffer(color: .green)
        await withCheckedContinuation { continuation in
            writer.queue.async {
                writer.setFrame(image, source: 0)
                continuation.resume()
            }
        }
        let session = await writer.stop()
        #expect(session.failure == nil)
        #expect(session.frames == 1)
    }

    private final class PreviewFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [CGImage] = []
        func append(_ image: CGImage) { lock.withLock { images.append(image) } }
        var snapshot: [CGImage] { lock.withLock { images } }
    }

    private func continuousAudio(
        at url: URL, seconds: Double, activeRange: Range<Double>? = nil
    ) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000))
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for index in 0..<48000 {
                channels[channel][index] = Float(sin(2 * .pi * 440 * Double(index) / 48000)) * 0.4
            }
        }
        var remaining = Int((seconds * 48000).rounded())
        var written = 0
        while remaining > 0 {
            let count = min(48000, remaining)
            if let activeRange {
                for index in 0..<count {
                    let time = Double(written + index) / 48000
                    let value =
                        activeRange.contains(time)
                        ? Float(sin(2 * .pi * 440 * time)) * 0.4 : 0
                    for channel in 0..<2 { channels[channel][index] = value }
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            remaining -= count
            written += count
        }
    }

    private func audioFrequency(at url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var offset = 0
        var armed = false
        var crossings: [Int] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let values = try #require(buffer.floatChannelData)[0]
            for index in 0..<Int(buffer.frameLength) {
                if values[index] < -0.02 { armed = true }
                if armed && values[index] > 0.02 {
                    crossings.append(offset + index)
                    armed = false
                }
            }
            offset += Int(buffer.frameLength)
        }
        let first = try #require(crossings.first)
        let last = try #require(crossings.last)
        #expect(crossings.count > 10)
        return Double(crossings.count - 1) * file.processingFormat.sampleRate / Double(last - first)
    }

    private func audioHasSignal(_ asset: AVAsset) async throws -> Bool {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TimeLapseError.empty }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer(),
            let block = CMSampleBufferGetDataBuffer(sample)
        {
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Int16>.stride
            var values = [Int16](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: $0.count,
                    destination: $0.baseAddress!)
            }
            guard status == noErr else { throw TimeLapseError.empty }
            if values.contains(where: { abs(Int($0)) > 32 }) { return true }
        }
        return false
    }

    private func audioSample(at seconds: Double, frequency: Double = 440) throws -> CMSampleBuffer {
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
        var samples = (0..<4800).flatMap { index -> [Int16] in
            let value = Int16(sin(2 * .pi * frequency * (seconds + Double(index) / 48000)) * 12000)
            return [value, value]
        }
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block!,
                offsetIntoDestination: 0, dataLength: bytes.count)
        }
        #expect(status == noErr)

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

    private func timeLapseSettings() -> TimeLapseSettings {
        var settings = TimeLapseSettings()
        settings.mode = .timeLapse
        return settings
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
