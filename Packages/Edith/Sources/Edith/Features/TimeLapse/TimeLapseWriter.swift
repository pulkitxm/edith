import AVFoundation
import CoreImage
import EdithCore
import Foundation
import ScreenCaptureKit
import VideoToolbox

final class TimeLapseWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "edith.timelapse.writer", qos: .utility)
    let directory: URL
    private(set) var session: TimeLapseSession
    private var clock: TimeLapseClock
    private let sourceCount: Int
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var latest: [Int: CVPixelBuffer] = [:]
    private var video: Chunk?
    private var audio: [String: Chunk] = [:]
    private var sequence = 0
    private var pending = 0
    private var closing = false
    private var completion: (@Sendable (TimeLapseSession) -> Void)?
    private var timer: DispatchSourceTimer?
    private var lastDiskCheck = -Double.infinity
    private let failure: @Sendable (String) -> Void
    private let progress: @Sendable (Int64, Int64, Double) -> Void
    private var recordingOrigin: Double?
    private var recordingDate: Date?
    private var lastPreview = -Double.infinity
    private var lastProgress = -Double.infinity
    private var storedBytes: Int64 = 0
    private var previewEnabled = false
    private var previewPending = false
    private let preview: (@Sendable (CGImage) async -> Void)?
    private let availableBytes: @Sendable (URL) throws -> Int64

    private final class Chunk {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor?
        let file: String
        let kind: String
        var startedAt = Date()
        var frames = 0
        var origin: CMTime?
        var end = CMTime.zero

        init(
            writer: AVAssetWriter, input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor?, file: String, kind: String
        ) {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.file = file
            self.kind = kind
        }
    }

    init(
        directory: URL, session: TimeLapseSession, sourceCount: Int,
        availableBytes: @escaping @Sendable (URL) throws -> Int64 = {
            try TimeLapseWriter.freeBytes($0)
        },
        failure: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (Int64, Int64, Double) -> Void,
        preview: (@Sendable (CGImage) async -> Void)? = nil
    ) throws {
        try session.validate()
        guard sourceCount > 0, sourceCount <= 16 else { throw TimeLapseError.missingSource }
        self.directory = directory
        self.session = session
        self.sourceCount = sourceCount
        self.availableBytes = availableBytes
        self.failure = failure
        self.progress = progress
        self.preview = preview
        clock = TimeLapseClock(interval: session.settings.captureInterval)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkDisk(at: ProcessInfo.processInfo.systemUptime)
        try save()
    }

    static func freeBytes(_ directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw TimeLapseError.encoding("Could not read the recording drive's free space.")
        }
        return bytes
    }

    func startTimer() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now(), repeating: session.settings.captureInterval,
                leeway: .milliseconds(session.settings.mode == .standard ? 1 : 50))
            timer.setEventHandler { [weak self] in
                self?.capture(at: ProcessInfo.processInfo.systemUptime)
            }
            self.timer = timer
            timer.resume()
        }
    }

    func setPreviewEnabled(_ enabled: Bool) {
        queue.async { [self] in previewEnabled = enabled }
    }

    func ingest(_ sample: CMSampleBuffer, source: Int, kind: String) {
        guard !closing, CMSampleBufferIsValid(sample) else { return }
        if kind == "video" {
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                let status = attachments.first?[.status] as? Int
            else { return }
            if status == SCFrameStatus.blank.rawValue || status == SCFrameStatus.suspended.rawValue
                || status == SCFrameStatus.stopped.rawValue
            {
                latest[source] = nil
                return
            }
            guard status == SCFrameStatus.complete.rawValue,
                let buffer = CMSampleBufferGetImageBuffer(sample)
            else { return }
            setFrame(buffer, source: source)
        } else {
            do { try appendAudio(sample, kind: kind) } catch { fail(error) }
        }
    }

    func setFrame(_ buffer: CVPixelBuffer, source: Int) {
        guard !closing else { return }
        latest[source] = buffer
        if timer != nil, clock.frames == 0 || session.settings.mode == .standard {
            capture(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    func capture(at uptime: Double) {
        guard !closing, latest.count == sourceCount, clock.isDue(at: uptime) else { return }
        do {
            try checkDisk(at: uptime)
            if session.settings.mode == .standard, let video, let origin = video.origin,
                uptime - origin.seconds >= 300
            {
                video.end = CMTime(seconds: 300, preferredTimescale: 60000)
                self.video = nil
                finish(video)
            }
            if video == nil { video = try makeChunk(kind: "video") }
            guard let video else { return }
            guard video.writer.status == .writing else {
                throw video.writer.error
                    ?? TimeLapseError.encoding("The video encoder stopped unexpectedly.")
            }
            guard video.input.isReadyForMoreMediaData, let adaptor = video.adaptor,
                let pool = adaptor.pixelBufferPool, pending < 3
            else { return }
            var raw: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &raw) == kCVReturnSuccess,
                let buffer = raw
            else { throw TimeLapseError.encoding("Could not allocate a video frame.") }
            render(to: buffer)
            if recordingOrigin == nil { recordingOrigin = uptime; recordingDate = Date() }
            if video.origin == nil {
                video.origin = CMTime(seconds: uptime, preferredTimescale: 60000)
                video.startedAt = recordingDate!.addingTimeInterval(uptime - recordingOrigin!)
            }
            let time =
                session.settings.mode == .standard
                ? CMTimeSubtract(CMTime(seconds: uptime, preferredTimescale: 60000), video.origin!)
                : CMTime(value: Int64(video.frames), timescale: session.settings.outputFPS)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw video.writer.error
                    ?? TimeLapseError.encoding("The video encoder rejected a frame.")
            }
            video.frames += 1
            video.end = CMTimeAdd(time, CMTime(value: 1, timescale: session.settings.outputFPS))
            clock.accepted(at: uptime)
            if session.settings.mode == .timeLapse {
                timer?.schedule(
                    deadline: .now() + session.settings.interval,
                    repeating: session.settings.interval, leeway: .milliseconds(50))
            }
            if previewEnabled, !previewPending, uptime - lastPreview >= 0.1, let preview {
                let image = CIImage(cvPixelBuffer: buffer)
                let scale = min(1, 960 / image.extent.width, 540 / image.extent.height)
                let thumbnail = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let bounds = CGRect(
                    x: 0, y: 0, width: floor(thumbnail.extent.width),
                    height: floor(thumbnail.extent.height))
                if let image = context.createCGImage(
                    thumbnail, from: bounds, format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
                {
                    lastPreview = uptime
                    previewPending = true
                    Task { [weak self] in
                        await preview(image)
                        guard let self else { return }
                        self.queue.async { [weak self] in self?.previewPending = false }
                    }
                }
            }
            if uptime - lastProgress >= 0.25 || clock.frames == 1 {
                let activeBytes = [video] + Array(audio.values)
                let bytes = activeBytes.reduce(storedBytes) { result, chunk in
                    result + fileBytes(chunk.file)
                }
                lastProgress = uptime
                let seconds =
                    session.settings.mode == .standard
                    ? uptime - recordingOrigin! + 1 / Double(session.settings.outputFPS)
                    : clock.playbackSeconds
                progress(clock.frames, bytes, seconds)
            }
            if video.frames >= session.settings.segmentFrameLimit {
                self.video = nil
                finish(video)
            }
        } catch { fail(error) }
    }

    private func render(to buffer: CVPixelBuffer) {
        let bounds = CGRect(x: 0, y: 0, width: session.width, height: session.height)
        let columns = Int(ceil(sqrt(Double(sourceCount))))
        let rows = (sourceCount + columns - 1) / columns
        let tileWidth = bounds.width / Double(columns)
        let tileHeight = bounds.height / Double(rows)
        var canvas = CIImage(color: .black).cropped(to: bounds)
        for index in 0..<sourceCount {
            guard let buffer = latest[index] else { continue }
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = min(tileWidth / image.extent.width, tileHeight / image.extent.height)
            let x =
                Double(index % columns) * tileWidth + (tileWidth - image.extent.width * scale) / 2
            let y =
                Double(rows - 1 - index / columns) * tileHeight
                + (tileHeight - image.extent.height * scale) / 2
            let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: x, y: y))
            canvas = fitted.composited(over: canvas)
        }
        context.render(
            canvas, to: buffer, bounds: bounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func appendAudio(_ sample: CMSampleBuffer, kind: String) throws {
        guard
            (kind == "system" && session.settings.systemAudio)
                || (kind == "microphone" && session.settings.microphoneID != nil)
        else { return }
        if session.settings.mode == .standard, recordingOrigin == nil { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric else { return }
        try checkDisk(at: ProcessInfo.processInfo.systemUptime)
        if let chunk = audio[kind], let origin = chunk.origin,
            CMTimeSubtract(timestamp, origin).seconds >= 900
        {
            audio[kind] = nil
            finish(chunk)
        }
        if audio[kind] == nil { audio[kind] = try makeChunk(kind: kind) }
        guard let chunk = audio[kind] else { return }
        guard chunk.writer.status == .writing else {
            throw chunk.writer.error
                ?? TimeLapseError.encoding("Audio recording stopped unexpectedly.")
        }
        guard chunk.input.isReadyForMoreMediaData else { return }
        if chunk.origin == nil {
            chunk.origin = timestamp
            if session.settings.mode == .standard, let recordingOrigin, let recordingDate {
                chunk.startedAt = recordingDate.addingTimeInterval(
                    timestamp.seconds - recordingOrigin)
            }
        }
        let time = CMTimeSubtract(timestamp, chunk.origin!)
        var count = 0
        guard
            CMSampleBufferGetSampleTimingInfoArray(
                sample, entryCount: 0,
                arrayToFill: nil, entriesNeededOut: &count) == noErr
        else {
            throw TimeLapseError.encoding("Could not read audio timing.")
        }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        guard
            CMSampleBufferGetSampleTimingInfoArray(
                sample, entryCount: count,
                arrayToFill: &timing, entriesNeededOut: &count) == noErr
        else {
            throw TimeLapseError.encoding("Could not read audio timing.")
        }
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(
                timing[index].presentationTimeStamp, chunk.origin!)
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMTimeSubtract(
                    timing[index].decodeTimeStamp, chunk.origin!)
            }
        }
        var retimed: CMSampleBuffer?
        guard
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample, sampleTimingEntryCount: count,
                sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr,
            let retimed, chunk.input.append(retimed)
        else {
            throw chunk.writer.error ?? TimeLapseError.encoding("Could not encode audio.")
        }
        chunk.frames += 1
        let duration = CMSampleBufferGetDuration(sample)
        chunk.end = CMTimeAdd(
            time, duration.isNumeric ? duration : CMTime(value: 1, timescale: 48000))
    }

    private func makeChunk(kind: String) throws -> Chunk {
        let file = String(format: "%@-%06d.mov", kind, sequence)
        sequence += 1
        let writer = try AVAssetWriter(
            outputURL: directory.appendingPathComponent(file), fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let settings: [String: Any]
        if kind == "video" {
            settings = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: session.width, AVVideoHeightKey: session.height,
                AVVideoEncoderSpecificationKey: [
                    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String:
                        true
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: session.settings.videoBitRate,
                    AVVideoExpectedSourceFrameRateKey: session.settings.outputFPS,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        } else {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000,
            ]
        }
        let input = AVAssetWriterInput(
            mediaType: kind == "video" ? .video : .audio,
            outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw TimeLapseError.encoding("The selected encoder is unavailable.")
        }
        writer.add(input)
        let adaptor =
            kind == "video"
            ? AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: session.width,
                    kCVPixelBufferHeightKey as String: session.height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]) : nil
        guard writer.startWriting() else {
            throw writer.error ?? TimeLapseError.encoding("Could not start recording.")
        }
        writer.startSession(atSourceTime: .zero)
        return Chunk(writer: writer, input: input, adaptor: adaptor, file: file, kind: kind)
    }

    private func checkDisk(at uptime: Double) throws {
        guard uptime - lastDiskCheck >= 1 else { return }
        lastDiskCheck = uptime
        guard try availableBytes(directory) > TimeLapseSettings.diskReserve else {
            throw TimeLapseError.diskFull
        }
    }

    private func finish(_ chunk: Chunk) {
        guard chunk.frames > 0 else {
            chunk.writer.cancelWriting()
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(chunk.file))
            return
        }
        pending += 1
        chunk.writer.endSession(atSourceTime: chunk.end)
        chunk.input.markAsFinished()
        chunk.writer.finishWriting { [self] in
            queue.async { [self] in
                pending -= 1
                if chunk.writer.status == .completed {
                    session.segments.append(
                        .init(
                            file: chunk.file, kind: chunk.kind,
                            frames: chunk.kind == "video" ? chunk.frames : 0,
                            startedAt: chunk.startedAt, duration: chunk.end.seconds))
                    session.segments.sort { $0.file < $1.file }
                    storedBytes += fileBytes(chunk.file)
                    do { try save() } catch { fail(error) }
                } else {
                    fail(
                        chunk.writer.error
                            ?? TimeLapseError.encoding("A recording segment could not be saved."))
                }
                completeIfReady()
            }
        }
    }

    func stop(reason: String? = nil) async -> TimeLapseSession {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                completion = { continuation.resume(returning: $0) }
                closing = true
                timer?.cancel()
                timer = nil
                latest.removeAll()
                if let reason { session.failure = reason }
                if let video {
                    if session.settings.mode == .standard, let origin = video.origin {
                        let end = CMTime(
                            seconds: ProcessInfo.processInfo.systemUptime - origin.seconds,
                            preferredTimescale: 60000)
                        if CMTimeCompare(end, video.end) > 0 { video.end = end }
                    }
                    self.video = nil
                    finish(video)
                }
                let chunks = Array(audio.values)
                audio.removeAll()
                for chunk in chunks { finish(chunk) }
                completeIfReady()
            }
        }
    }

    private func completeIfReady() {
        guard closing, pending == 0, let completion else { return }
        self.completion = nil
        session.endedAt = Date()
        if session.frames == 0, session.failure == nil {
            session.failure = TimeLapseError.empty.localizedDescription
        }
        do { try save() } catch { session.failure = error.localizedDescription }
        completion(session)
    }

    private func fail(_ error: Error) {
        guard session.failure == nil else { return }
        session.failure = error.localizedDescription
        timer?.cancel()
        timer = nil
        closing = true
        failure(error.localizedDescription)
    }

    private func save() throws {
        try JSONEncoder().encode(session).write(
            to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func fileBytes(_ file: String) -> Int64 {
        let values = try? directory.appendingPathComponent(file).resourceValues(forKeys: [
            .fileSizeKey
        ])
        return Int64(values?.fileSize ?? 0)
    }
}
