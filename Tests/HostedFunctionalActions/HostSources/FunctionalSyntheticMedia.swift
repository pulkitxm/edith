import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import WorkerFixtureSupport

@available(macOS 26.0, *)
@MainActor
enum FunctionalSyntheticMedia {
    struct ExactTime: Encodable, Equatable {
        let value: String
        let timescale: Int32

        init(_ time: CMTime) throws {
            guard time.isNumeric, time.epoch == 0, time.timescale > 0 else {
                throw FunctionalFailure.invalid("numeric zero-epoch media time")
            }
            value = String(time.value)
            timescale = time.timescale
        }

        private var time: CMTime { CMTime(value: Int64(value)!, timescale: timescale) }

        static func == (left: Self, right: Self) -> Bool { left.time == right.time }
    }

    struct Decoded {
        let frames: Int
        let durationMicroseconds: Int64
        let sampleMicroseconds: [Int64]
        let durationTime: ExactTime
        let sampleTimes: [ExactTime]
        let pixelSHA256: String
        let encodedSHA256: String
        let encodedBytes: Int

        func matchesDecodedContent(_ other: Self) -> Bool {
            frames == other.frames && durationTime == other.durationTime
                && sampleTimes == other.sampleTimes && pixelSHA256 == other.pixelSHA256
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func finish() { lock.withLock { finished = true } }
        var isFinished: Bool { lock.withLock { finished } }
    }

    static func createTimeLapse(root: FunctionalPinnedPath, sourceCommit: String, session: String)
        async throws -> [String: String]
    {
        try await admit(root: root, sourceCommit: sourceCommit, session: session)
        let directory = root.url.appendingPathComponent(
            "inputs/timeLapse/saved-recording", isDirectory: true)
        let pinnedDirectory = try emptyPreparationDirectory(directory, root: root)
        let video = directory.appendingPathComponent("video.mp4")
        try await encodeVideo(
            video: video, pinnedDirectory: pinnedDirectory, width: 64, height: 64, frames: 60)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: video.path)
        let decoded = try await decode(
            video, root: root, sourceCommit: sourceCommit, session: session,
            frames: 60, seconds: 2)
        guard decoded.frames == 60 else {
            throw FunctionalFailure.invalid("synthetic encoded frame count")
        }
        let started: Double = 725_846_400
        let metadata: [String: Any] = [
            "id": session.uppercased(), "startedAt": started, "endedAt": started + 2,
            "width": 64, "height": 64,
            "settings": [
                "mode": "Standard", "frameRate": 30, "interval": 5,
                "maximumDimension": 3840, "systemAudio": false, "showCursor": true,
                "keepAwake": true,
            ],
            "segments": [
                [
                    "file": "video.mp4", "kind": "video", "frames": 60,
                    "startedAt": started, "duration": 2,
                ]
            ],
        ]
        let metadataURL = directory.appendingPathComponent("session.json")
        guard
            FileManager.default.createFile(
                atPath: metadataURL.path,
                contents: try FunctionalBytes.canonical(metadata),
                attributes: [.posixPermissions: 0o600])
        else { throw FunctionalFailure.invalid("synthetic saved session") }
        try pinnedDirectory.requireCurrent()
        return [
            "saved-recording": directory.path, "saved-session": metadataURL.path,
            "saved-video": video.path,
        ]
    }

    private static func encodeVideo(
        video: URL, pinnedDirectory: FunctionalPinnedPath, width: Int, height: Int, frames: Int
    ) async throws {
        guard
            (width == 64 && height == 64 && frames == 60)
                || (width == 320 && height == 180 && frames == 30),
            video.deletingLastPathComponent() == pinnedDirectory.url
        else {
            throw FunctionalFailure.invalid("finite source-owned video encoder recipe")
        }
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
            ])
        guard writer.canAdd(input) else {
            throw FunctionalFailure.invalid("synthetic video writer input")
        }
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let completion = Completion()
        var callbackStarted = false
        do {
            for frame in 0..<frames {
                try pinnedDirectory.requireCurrent()
                var attributes = CVPixelBufferCreationAttributes(
                    pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA),
                    size: .init(width: width, height: height))
                attributes.backing = .ioSurface
                var buffer = try CVMutablePixelBuffer(attributes)
                try buffer.accessUnsafeMutableRawPlaneBytes { planes in
                    guard planes.count == 1, let plane = planes.first,
                        plane.properties.size.width == width,
                        plane.properties.size.height == height,
                        plane.properties.bytesPerRow >= width * 4,
                        let base = plane.bytes.baseAddress,
                        plane.bytes.count >= plane.properties.bytesPerRow * height
                    else { throw FunctionalFailure.invalid("synthetic owned pixel geometry") }
                    for y in 0..<height {
                        let row = base.advanced(by: y * plane.properties.bytesPerRow)
                            .assumingMemoryBound(to: UInt8.self)
                        for x in 0..<width {
                            row[x * 4] = UInt8((x * 3 + frame) % 256)
                            row[x * 4 + 1] = UInt8((y * 3 + frame * 2) % 256)
                            row[x * 4 + 2] = UInt8((x + y + frame * 3) % 256)
                            row[x * 4 + 3] = 255
                        }
                    }
                }
                let pixel = CVReadOnlyPixelBuffer(buffer)
                while try !receiver.appendImmediately(
                    pixel, with: CMTime(value: Int64(frame), timescale: 30))
                {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline, writer.status == .writing else {
                        throw FunctionalFailure.timeout("synthetic video append")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            receiver.finish()
            callbackStarted = true
            writer.finishWriting { completion.finish() }
            while !completion.isFinished {
                if Task.isCancelled || ContinuousClock.now >= deadline {
                    writer.cancelWriting()
                    let joinDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while !completion.isFinished, ContinuousClock.now < joinDeadline {
                        await retirementPause()
                    }
                    guard completion.isFinished else {
                        throw FunctionalFailure.invalid("synthetic encoder callback did not join")
                    }
                    throw FunctionalFailure.timeout("synthetic encoder completion")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard writer.status == .completed else {
                throw FunctionalFailure.invalid("synthetic encoded video")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            if callbackStarted {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !completion.isFinished, ContinuousClock.now < deadline {
                    await retirementPause()
                }
                guard completion.isFinished else {
                    throw FunctionalFailure.invalid("unretired synthetic encoder callback")
                }
            }
            throw error
        }
    }

    struct DecodedAudio {
        let sampleFrames: Int
        let durationTime: ExactTime
        let pcmSHA256: String
        let encodedSHA256: String
        let encodedBytes: Int
    }

    static func createDownloadsAudio(
        root: FunctionalPinnedPath, sourceCommit: String, session: String,
        policy: WorkerFixtureRolePolicy
    ) async throws -> DecodedAudio {
        try await admit(root: root, sourceCommit: sourceCommit, session: session)
        let resolved = try policy.resolvedOwnedPaths(
            root: root.url.path, session: session, phase: .initial)
        guard policy.owner == "downloads",
            let scope = resolved.first(where: { $0.scope.name == "audio-library" }),
            scope.scope.kind == .directory, scope.scope.purpose == .immutableInput,
            scope.scope.root == .ownerHome, scope.scope.components == [.literal("audio-library")],
            scope.scope.initialState == .present, scope.scope.allowedStates == [.present],
            scope.scope.mutableFiles.isEmpty, scope.scope.immutableFiles.count == 1,
            scope.scope.immutableFiles[0].components == ["Synthetic saved download.m4a"],
            scope.scope.immutableFiles[0].maximumBytes >= 1_048_576,
            scope.path == root.url.path + "/downloads-home/audio-library"
        else {
            throw FunctionalFailure.invalid("source finite Downloads synthetic audio input")
        }
        let directory = try emptyPreparationDirectory(URL(fileURLWithPath: scope.path), root: root)
        let url = directory.url.appendingPathComponent("Synthetic saved download.m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            ])
        guard writer.canAdd(input) else {
            throw FunctionalFailure.invalid("synthetic audio writer input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw FunctionalFailure.invalid("synthetic audio writer start")
        }
        writer.startSession(atSourceTime: .zero)
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format) == noErr, let format
        else {
            writer.cancelWriting()
            throw FunctionalFailure.invalid("synthetic audio PCM format")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let completion = Completion()
        var callbackStarted = false
        do {
            for first in stride(from: 0, to: 96_000, by: 1024) {
                try directory.requireCurrent()
                try Task.checkCancellation()
                let count = min(1024, 96_000 - first)
                var samples = [Float](repeating: 0, count: count * 2)
                for frame in 0..<count {
                    let value = Float(
                        sin(Double(first + frame) * 2 * Double.pi * 440 / 48_000) * 0.125)
                    samples[frame * 2] = value
                    samples[frame * 2 + 1] = value
                }
                var block: CMBlockBuffer?
                guard
                    CMBlockBufferCreateWithMemoryBlock(
                        allocator: kCFAllocatorDefault,
                        memoryBlock: nil, blockLength: samples.count * MemoryLayout<Float>.size,
                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                        offsetToData: 0,
                        dataLength: samples.count * MemoryLayout<Float>.size, flags: 0,
                        blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
                    samples.withUnsafeBytes({
                        CMBlockBufferReplaceDataBytes(
                            with: $0.baseAddress!,
                            blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
                    }) == kCMBlockBufferNoErr
                else {
                    throw FunctionalFailure.invalid("synthetic audio owned PCM bytes")
                }
                var sample: CMSampleBuffer?
                guard
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                        allocator: kCFAllocatorDefault,
                        dataBuffer: block, formatDescription: format, sampleCount: count,
                        presentationTimeStamp: CMTime(value: Int64(first), timescale: 48_000),
                        packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample
                else {
                    throw FunctionalFailure.invalid("synthetic audio PCM sample")
                }
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline, writer.status == .writing else {
                        throw FunctionalFailure.timeout("synthetic audio append")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard input.append(sample) else {
                    throw FunctionalFailure.invalid("synthetic audio PCM encoding")
                }
            }
            input.markAsFinished()
            callbackStarted = true
            writer.finishWriting { completion.finish() }
            while !completion.isFinished {
                if Task.isCancelled || ContinuousClock.now >= deadline {
                    writer.cancelWriting()
                    let joinDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while !completion.isFinished, ContinuousClock.now < joinDeadline {
                        await retirementPause()
                    }
                    guard completion.isFinished else {
                        throw FunctionalFailure.invalid("synthetic audio callback did not join")
                    }
                    throw FunctionalFailure.timeout("synthetic audio completion")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard writer.status == .completed else {
                throw FunctionalFailure.invalid("synthetic encoded audio")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            if callbackStarted {
                let joinDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !completion.isFinished, ContinuousClock.now < joinDeadline {
                    await retirementPause()
                }
                guard completion.isFinished else {
                    throw FunctionalFailure.invalid("unretired synthetic audio callback")
                }
            }
            throw error
        }
        try directory.requireCurrent()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let result = try await decodeDownloadsAudio(
            url, root: root, sourceCommit: sourceCommit, session: session)
        try directory.requireCurrent()
        return result
    }

    static func decodeDownloadsAudio(
        _ url: URL, root: FunctionalPinnedPath, sourceCommit: String,
        session: String
    ) async throws -> DecodedAudio {
        try await admit(root: root, sourceCommit: sourceCommit, session: session)
        guard
            url.path == root.url.path + "/downloads-home/audio-library/Synthetic saved download.m4a"
        else {
            throw FunctionalFailure.invalid("source finite audio decoding path")
        }
        let pinned = try FunctionalPinnedPath(
            url, directory: false, privateMode: true, maximum: 1_048_576)
        let encoded = try pinned.read()
        guard encoded.count > 32, encoded[4..<8] == Data("ftyp".utf8) else {
            throw FunctionalFailure.invalid("synthetic audio container")
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        guard tracks.count == 1, video.isEmpty, duration.isNumeric, duration.epoch == 0,
            duration.seconds.isFinite, abs(duration.seconds - 2) <= 1024.0 / 48_000
        else {
            throw FunctionalFailure.invalid("synthetic independent audio metadata")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: tracks[0],
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
        guard reader.canAdd(output) else {
            throw FunctionalFailure.invalid("synthetic audio decode input")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw FunctionalFailure.invalid("synthetic audio decode start")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var count = 0
        var previous: CMTime?
        var digest = SHA256()
        var nonzero = false
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let frames = CMSampleBufferGetNumSamples(sample)
            guard ContinuousClock.now < deadline, frames > 0, frames <= 16_384,
                count + frames <= 98_048, timestamp.isNumeric, timestamp.epoch == 0,
                timestamp >= .zero, previous.map({ timestamp > $0 }) ?? true,
                let format = CMSampleBufferGetFormatDescription(sample),
                let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                description.pointee.mSampleRate == 48_000,
                description.pointee.mChannelsPerFrame == 2,
                description.pointee.mFormatID == kAudioFormatLinearPCM,
                let block = CMSampleBufferGetDataBuffer(sample),
                CMBlockBufferGetDataLength(block) == frames * 8
            else {
                throw FunctionalFailure.invalid("synthetic decoded PCM samples")
            }
            var bytes = Data(count: frames * 8)
            guard
                bytes.withUnsafeMutableBytes({
                    CMBlockBufferCopyDataBytes(
                        block, atOffset: 0,
                        dataLength: $0.count, destination: $0.baseAddress!)
                }) == kCMBlockBufferNoErr
            else {
                throw FunctionalFailure.invalid("synthetic decoded audio bytes")
            }
            nonzero = nonzero || bytes.contains(where: { $0 != 0 })
            digest.update(data: bytes)
            count += frames
            previous = timestamp
        }
        guard reader.status == .completed, (94_976...98_048).contains(count), nonzero,
            try pinned.read() == encoded
        else { throw FunctionalFailure.invalid("synthetic audio decode completion or drift") }
        try root.requireCurrent()
        return DecodedAudio(
            sampleFrames: count, durationTime: try ExactTime(duration),
            pcmSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            encodedSHA256: FunctionalBytes.digest(encoded), encodedBytes: encoded.count)
    }

    static func createStudioSource(
        root: FunctionalPinnedPath, sourceCommit: String, session: String,
        policy: WorkerFixtureRolePolicy
    ) async throws -> Decoded {
        try await admit(root: root, sourceCommit: sourceCommit, session: session)
        let paths = try policy.resolvedOwnedPaths(
            root: root.url.path, session: session, phase: .initial)
        guard policy.owner == "studio", policy.primaryRole.rawValue == "app",
            let project = paths.first(where: { $0.scope.name == "studio-project" }),
            let source = paths.first(where: { $0.scope.name == "studio-source-video" }),
            project.scope.kind == .file, source.scope.kind == .file,
            project.scope.purpose == .immutableInput, source.scope.purpose == .immutableInput,
            project.scope.root == .ownerInputs, source.scope.root == .ownerInputs,
            project.scope.components == [.literal("retained.openscreen")],
            source.scope.components == [.literal("source.mp4")],
            project.scope.initialState == .present, source.scope.initialState == .present,
            project.scope.mutableFiles.isEmpty, source.scope.mutableFiles.isEmpty,
            project.path == root.url.path + "/inputs/studio/retained.openscreen",
            source.path == root.url.path + "/inputs/studio/source.mp4"
        else {
            throw FunctionalFailure.invalid("source finite Studio input pair")
        }
        let directory = try FunctionalPinnedPath(
            URL(fileURLWithPath: source.path).deletingLastPathComponent(), directory: true,
            privateMode: true)
        let projectFile = try FunctionalPinnedPath(
            URL(fileURLWithPath: project.path), directory: false, privateMode: true,
            maximum: 1_048_576)
        let projectBytes = try projectFile.read()
        let body = try FunctionalBytes.object(projectBytes)
        guard try FunctionalBytes.integer(body, "schemaVersion") == 7,
            let settings = body["edithVideoSettings"] as? [String: Any],
            try FunctionalBytes.integer(settings, "width") == 320,
            try FunctionalBytes.integer(settings, "height") == 180,
            try FunctionalBytes.integer(settings, "frameRateNumerator") == 30,
            try FunctionalBytes.integer(settings, "frameRateDenominator") == 1,
            let assets = body["assets"] as? [[String: Any]], assets.count == 1,
            let asset = assets.first, asset["kind"] as? String == "video",
            asset["originalPath"] as? String == source.path,
            let assetID = asset["id"] as? String, !assetID.isEmpty,
            let duration = asset["durationSec"] as? NSNumber, duration.doubleValue == 1,
            let timeline = body["timeline"] as? [String: Any],
            let clips = timeline["clips"] as? [[String: Any]], clips.count == 120
        else {
            throw FunctionalFailure.invalid("source-authored Studio schema7 120 clip project")
        }
        for (index, clip) in clips.enumerated() {
            guard clip["assetId"] as? String == assetID,
                (clip["sourceStartSec"] as? NSNumber)?.doubleValue == 0,
                (clip["sourceEndSec"] as? NSNumber)?.doubleValue == 1,
                (clip["timelineStartSec"] as? NSNumber)?.doubleValue == Double(index),
                (clip["timelineEndSec"] as? NSNumber)?.doubleValue == Double(index + 1)
            else {
                throw FunctionalFailure.invalid("actual Studio120 source timeline")
            }
        }
        var state = stat()
        guard lstat(source.path, &state) != 0, errno == ENOENT else {
            throw FunctionalFailure.invalid("Studio source already prepared")
        }
        let video = URL(fileURLWithPath: source.path)
        try await encodeVideo(
            video: video, pinnedDirectory: directory, width: 320, height: 180, frames: 30)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: video.path)
        let result = try await decode(
            video, root: root, sourceCommit: sourceCommit, session: session,
            frames: 30, seconds: 1, width: 320, height: 180)
        guard result.frames == 30,
            result.durationTime == (try ExactTime(CMTime(value: 30, timescale: 30))),
            result.encodedBytes <= source.scope.maximumBytes,
            try projectFile.read() == projectBytes
        else {
            throw FunctionalFailure.invalid(
                "actual independent Studio input decode or project drift")
        }
        try directory.requireCurrent()
        try root.requireCurrent()
        return result
    }

    private static func emptyPreparationDirectory(_ url: URL, root: FunctionalPinnedPath) throws
        -> FunctionalPinnedPath
    {
        try root.requireCurrent()
        guard url.path.hasPrefix(root.url.path + "/"), url.path == url.standardizedFileURL.path
        else {
            throw FunctionalFailure.invalid("source finite synthetic media directory")
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let pinned = try FunctionalPinnedPath(url, directory: true, privateMode: true)
        guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
            throw FunctionalFailure.invalid("synthetic media already constructed")
        }
        try pinned.requireCurrent()
        return pinned
    }

    static func decode(
        _ url: URL, root: FunctionalPinnedPath, sourceCommit: String, session: String,
        frames: Int, seconds: Double, width: Int = 64, height: Int = 64
    ) async throws -> Decoded {
        try await admit(root: root, sourceCommit: sourceCommit, session: session)
        guard [(64, 64), (320, 180)].contains(where: { $0 == (width, height) }),
            url.path.hasPrefix(root.url.path + "/"), frames >= 1, frames <= 120,
            seconds > 0, seconds <= 5, abs(seconds - Double(frames) / 30) <= 1.0 / 30
        else { throw FunctionalFailure.invalid("synthetic decoding bounds") }
        let pinned = try FunctionalPinnedPath(url, directory: false, maximum: 16_777_216)
        let bytes = try pinned.read()
        guard bytes.count > 32, bytes[4..<8] == Data("ftyp".utf8) else {
            throw FunctionalFailure.invalid("synthetic encoded container")
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        guard tracks.count == 1, audio.isEmpty, duration.isNumeric, duration.epoch == 0,
            duration.seconds.isFinite,
            duration.seconds > 0, duration.seconds <= 5,
            abs(duration.seconds - seconds) <= 1.0 / 30,
            try await tracks[0].load(.naturalSize) == CGSize(width: width, height: height)
        else { throw FunctionalFailure.invalid("synthetic independent media metadata") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: tracks[0],
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        guard reader.canAdd(output) else {
            throw FunctionalFailure.invalid("synthetic decode input")
        }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { if reader.status == .reading { reader.cancelReading() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var count = 0
        var samples: [Int64] = []
        var sampleTimes: [ExactTime] = []
        var lastTimestamp: CMTime?
        var digest = SHA256()
        while let readySample = try await provider.next() {
            try Task.checkCancellation()
            let timestamp = readySample.presentationTimeStamp
            guard ContinuousClock.now < deadline, count < frames,
                timestamp.isNumeric, timestamp.epoch == 0, timestamp.seconds.isFinite,
                timestamp >= .zero,
                timestamp < duration, timestamp.seconds <= 5
            else { throw FunctionalFailure.invalid("synthetic sample timestamp") }
            let microseconds = Int64((timestamp.seconds * 1_000_000).rounded())
            guard lastTimestamp.map({ timestamp > $0 }) ?? true else {
                throw FunctionalFailure.invalid("synthetic sample order")
            }
            lastTimestamp = timestamp
            sampleTimes.append(try ExactTime(timestamp))
            let frameBytes: Data = try readySample.withUnsafeSampleBuffer { sample in
                guard let image = CMSampleBufferGetImageBuffer(sample),
                    CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height,
                    CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
                    CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess
                else { throw FunctionalFailure.invalid("synthetic decoded frame") }
                defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(image) else {
                    throw FunctionalFailure.invalid("synthetic decoded frame bytes")
                }
                let stride = CVPixelBufferGetBytesPerRow(image)
                guard stride >= width * 4 else {
                    throw FunctionalFailure.invalid("synthetic decoded row")
                }
                var bytes = Data(capacity: width * height * 4)
                for row in 0..<height {
                    bytes.append(Data(bytes: base.advanced(by: row * stride), count: width * 4))
                }
                return bytes
            }
            samples.append(microseconds)
            digest.update(data: frameBytes)
            count += 1
        }
        guard reader.status == .completed, count == frames, try pinned.read() == bytes else {
            throw FunctionalFailure.invalid("synthetic decode completion or source drift")
        }
        try root.requireCurrent()
        return Decoded(
            frames: count, durationMicroseconds: Int64((duration.seconds * 1_000_000).rounded()),
            sampleMicroseconds: samples, durationTime: try ExactTime(duration),
            sampleTimes: sampleTimes,
            pixelSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            encodedSHA256: FunctionalBytes.digest(bytes), encodedBytes: bytes.count)
    }

    private static func retirementPause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
                continuation.resume()
            }
        }
    }

    private static func admit(root: FunctionalPinnedPath, sourceCommit: String, session: String)
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard sourceCommit == FunctionalProducerBuild.sourceCommit,
            session == FunctionalProducerBuild.session,
            FunctionalBytes.uuid(session),
            root.url.path == FunctionalProducerBuild.root,
            root.url.path == (environment["RUNNER_TEMP"] ?? "") + "/functional-fixture-" + session
        else { throw FunctionalFailure.invalid("source-bound hosted synthetic media only") }
        _ = try await FunctionalHostedRunAdmission.observe(
            pins: FunctionalProducerBuild.hostedRunPins, environment: environment)
        try root.requireCurrent()
    }
}
