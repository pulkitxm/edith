import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

@available(macOS 26.0, *)
@MainActor
enum FunctionalSyntheticMedia {
    struct ExactTime: Encodable, Equatable {
        let value: String
        let timescale: Int32

        init(_ time: CMTime) throws {
            guard time.isNumeric, time.epoch == 0, time.timescale > 0 else {
                throw FunctionalFailure.invalid("numeric zero-epoch media time") }
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

    static func createTimeLapse(root: FunctionalPinnedPath, sourceCommit: String, session: String) async throws -> [String: String] {
        try admit(root: root, sourceCommit: sourceCommit, session: session)
        let directory = root.url.appendingPathComponent("inputs/timeLapse/saved-recording", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw FunctionalFailure.invalid("saved recording already constructed")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let pinnedDirectory = try FunctionalPinnedPath(directory, directory: true, privateMode: true)
        let video = directory.appendingPathComponent("video.mp4")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
        ])
        guard writer.canAdd(input) else { throw FunctionalFailure.invalid("synthetic video writer input") }
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let completion = Completion()
        var callbackStarted = false
        do {
            for frame in 0..<60 {
                try pinnedDirectory.requireCurrent()
                var attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: 64, height: 64))
                attributes.backing = .ioSurface
                var buffer = try CVMutablePixelBuffer(attributes)
                try buffer.accessUnsafeMutableRawPlaneBytes { planes in
                    guard planes.count == 1, let plane = planes.first,
                        plane.properties.size.width == 64, plane.properties.size.height == 64,
                        plane.properties.bytesPerRow >= 256, let base = plane.bytes.baseAddress,
                        plane.bytes.count >= plane.properties.bytesPerRow * 64
                    else { throw FunctionalFailure.invalid("synthetic owned pixel geometry") }
                    for y in 0..<64 {
                        let row = base.advanced(by: y * plane.properties.bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<64 {
                            row[x * 4] = UInt8((x * 3 + frame) % 256)
                            row[x * 4 + 1] = UInt8((y * 3 + frame * 2) % 256)
                            row[x * 4 + 2] = UInt8((x + y + frame * 3) % 256)
                            row[x * 4 + 3] = 255
                        }
                    }
                }
                let pixel = CVReadOnlyPixelBuffer(buffer)
                while try !receiver.appendImmediately(pixel, with: CMTime(value: Int64(frame), timescale: 30)) {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline, writer.status == .writing else { throw FunctionalFailure.timeout("synthetic video append") }
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
                    guard completion.isFinished else { throw FunctionalFailure.invalid("synthetic encoder callback did not join") }
                    throw FunctionalFailure.timeout("synthetic encoder completion")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard writer.status == .completed else { throw FunctionalFailure.invalid("synthetic encoded video") }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            if callbackStarted {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !completion.isFinished, ContinuousClock.now < deadline { await retirementPause() }
                guard completion.isFinished else { throw FunctionalFailure.invalid("unretired synthetic encoder callback") }
            }
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: video.path)
        let decoded = try await decode(video, root: root, sourceCommit: sourceCommit, session: session,
            frames: 60, seconds: 2)
        guard decoded.frames == 60 else { throw FunctionalFailure.invalid("synthetic encoded frame count") }
        let started: Double = 725_846_400
        let metadata: [String: Any] = [
            "id": session.uppercased(), "startedAt": started, "endedAt": started + 2,
            "width": 64, "height": 64,
            "settings": ["mode": "Standard", "frameRate": 30, "interval": 5,
                "maximumDimension": 3840, "systemAudio": false, "showCursor": true, "keepAwake": true],
            "segments": [["file": "video.mp4", "kind": "video", "frames": 60,
                "startedAt": started, "duration": 2]],
        ]
        let metadataURL = directory.appendingPathComponent("session.json")
        guard FileManager.default.createFile(atPath: metadataURL.path,
            contents: try FunctionalBytes.canonical(metadata), attributes: [.posixPermissions: 0o600])
        else { throw FunctionalFailure.invalid("synthetic saved session") }
        try pinnedDirectory.requireCurrent()
        return ["saved-recording": directory.path, "saved-session": metadataURL.path,
            "saved-video": video.path]
    }

    static func decode(_ url: URL, root: FunctionalPinnedPath, sourceCommit: String, session: String,
        frames: Int, seconds: Double) async throws -> Decoded
    {
        try admit(root: root, sourceCommit: sourceCommit, session: session)
        guard url.path.hasPrefix(root.url.path + "/"), frames >= 1, frames <= 120,
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
        guard tracks.count == 1, audio.isEmpty, duration.isNumeric, duration.epoch == 0, duration.seconds.isFinite,
            duration.seconds > 0, duration.seconds <= 5,
            abs(duration.seconds - seconds) <= 1.0 / 30,
            try await tracks[0].load(.naturalSize) == CGSize(width: 64, height: 64)
        else { throw FunctionalFailure.invalid("synthetic independent media metadata") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(output) else { throw FunctionalFailure.invalid("synthetic decode input") }
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
                timestamp.isNumeric, timestamp.epoch == 0, timestamp.seconds.isFinite, timestamp >= .zero,
                timestamp < duration, timestamp.seconds <= 5
            else { throw FunctionalFailure.invalid("synthetic sample timestamp") }
            let microseconds = Int64((timestamp.seconds * 1_000_000).rounded())
            guard lastTimestamp.map({ timestamp > $0 }) ?? true else { throw FunctionalFailure.invalid("synthetic sample order") }
            lastTimestamp = timestamp
            sampleTimes.append(try ExactTime(timestamp))
            let frameBytes: Data = try readySample.withUnsafeSampleBuffer { sample in
                guard let image = CMSampleBufferGetImageBuffer(sample),
                    CVPixelBufferGetWidth(image) == 64, CVPixelBufferGetHeight(image) == 64,
                    CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
                    CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess
                else { throw FunctionalFailure.invalid("synthetic decoded frame") }
                defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(image) else { throw FunctionalFailure.invalid("synthetic decoded frame bytes") }
                let stride = CVPixelBufferGetBytesPerRow(image)
                guard stride >= 256 else { throw FunctionalFailure.invalid("synthetic decoded row") }
                var bytes = Data(capacity: 64 * 64 * 4)
                for row in 0..<64 { bytes.append(Data(bytes: base.advanced(by: row * stride), count: 64 * 4)) }
                return bytes
            }
            samples.append(microseconds)
            digest.update(data: frameBytes)
            count += 1
        }
        guard reader.status == .completed, count == frames, try pinned.read() == bytes else {
            throw FunctionalFailure.invalid("synthetic decode completion or source drift") }
        try root.requireCurrent()
        return Decoded(frames: count, durationMicroseconds: Int64((duration.seconds * 1_000_000).rounded()),
            sampleMicroseconds: samples, durationTime: try ExactTime(duration), sampleTimes: sampleTimes, pixelSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            encodedSHA256: FunctionalBytes.digest(bytes), encodedBytes: bytes.count)
    }

    private static func retirementPause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) { continuation.resume() }
        }
    }

    private static func admit(root: FunctionalPinnedPath, sourceCommit: String, session: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["RUNNER_OS"] == "macOS", environment["GITHUB_REPOSITORY"] == "pulkitxm/edith",
            environment["GITHUB_EVENT_NAME"] == "workflow_dispatch",
            environment["EXPECTED_SOURCE_SHA"] == sourceCommit, environment["GITHUB_SHA"] == sourceCommit,
            environment["EDITH_HOSTED_FUNCTIONAL_ACTIONS"] == "1",
            ["65671483", "320458784"].contains(environment["GITHUB_ACTOR_ID"] ?? ""),
            ["refs/heads/main", "refs/heads/feat/extension-marketplace"].contains(environment["GITHUB_REF"] ?? ""),
            FunctionalBytes.uuid(session),
            root.url.path == (environment["RUNNER_TEMP"] ?? "") + "/functional-fixture-" + session
        else { throw FunctionalFailure.invalid("hosted synthetic media only") }
        try root.requireCurrent()
    }
}
