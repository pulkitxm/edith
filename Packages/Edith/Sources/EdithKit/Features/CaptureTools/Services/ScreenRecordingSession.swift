import AVFoundation
import AppKit
import ScreenCaptureKit

public enum ScreenRecordingError: LocalizedError, Equatable {
    case busy
    case cancelled
    case permissionDenied
    case sourceUnavailable
    case microphoneUnavailable
    case writerFailed
    case captureFailed

    public var errorDescription: String? {
        switch self {
        case .busy: "A recording is already active."
        case .cancelled: "Recording was cancelled."
        case .permissionDenied: "Screen Recording access is required."
        case .sourceUnavailable: "The selected recording source is no longer available."
        case .microphoneUnavailable: "The microphone is unavailable."
        case .writerFailed: "The recording file could not be written."
        case .captureFailed: "ScreenCaptureKit stopped the recording unexpectedly."
        }
    }
}

public final class ScreenRecordingSession: NSObject, @unchecked Sendable {
    public var onUnexpectedStop: (@Sendable (ScreenRecordingError) -> Void)?
    public var onElapsedTime: (@Sendable (Double) -> Void)?

    private let region: ScreenRecordingRegion
    private let take: ScreenRecordingTake
    private let directory: URL?
    private let capturesSystemAudio: Bool
    private let capturesMicrophone: Bool
    private let frameRate: Int
    private let streamQueue = DispatchQueue(label: "com.pulkit.edith.recorder.stream")
    private let writerQueue = DispatchQueue(label: "com.pulkit.edith.recorder.writer")
    private let stateLock = NSLock()
    private let pauseClock = ScreenRecordingPauseClock()
    private var stream: SCStream?
    private var writer: ScreenRecordingWriter?
    private var microphone: ScreenRecordingMicrophone?
    private var pointer: ScreenRecordingPointerSampler?
    private var elapsedTimer: DispatchSourceTimer?
    private var startedAt = 0.0
    private var running = false
    private var stopping = false

    public init(
        take: ScreenRecordingTake, region: ScreenRecordingRegion,
        capturesSystemAudio: Bool, capturesMicrophone: Bool, frameRate: Int = 30,
        directory: URL? = nil
    ) {
        self.take = take
        self.region = region
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.frameRate = min(max(frameRate, 15), 60)
        self.directory = directory
    }

    public func start() async throws {
        guard stateLock.withLock({ !running && !stopping }) else {
            throw ScreenRecordingError.busy
        }
        let writer = try ScreenRecordingWriter(
            url: ScreenRecordingLibrary.masterURL(for: take.id, in: directory),
            size: region.pixelSize, frameRate: frameRate,
            systemAudio: capturesSystemAudio, microphone: capturesMicrophone,
            pauseClock: pauseClock)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenRecordingError.permissionDenied
        }
        guard let filter = Self.filter(region: region, content: content) else {
            throw ScreenRecordingError.sourceUnavailable
        }
        let configuration = Self.configuration(
            region: region, frameRate: frameRate, capturesSystemAudio: capturesSystemAudio)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        if capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: streamQueue)
        }
        guard writer.start() else { throw ScreenRecordingError.writerFailed }
        self.writer = writer
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            writer.cancel()
            self.writer = nil
            self.stream = nil
            throw ScreenRecordingError.captureFailed
        }
        let startedAt = CACurrentMediaTime()
        self.startedAt = startedAt
        pointer = ScreenRecordingPointerSampler(
            region: region, startedAt: startedAt, pauseClock: pauseClock)
        pointer?.start()
        if capturesMicrophone {
            let microphone = ScreenRecordingMicrophone()
            microphone.onSample = { [weak self] sample in self?.append(sample, kind: .microphone) }
            guard let clock = stream.synchronizationClock,
                await microphone.start(synchronizingTo: clock)
            else {
                await stop(discarding: true)
                throw ScreenRecordingError.microphoneUnavailable
            }
            self.microphone = microphone
        }
        stateLock.withLock { running = true }
        startElapsedTimer()
    }

    @discardableResult
    public func pause() -> Bool {
        guard stateLock.withLock({ running && !stopping }) else { return false }
        return pauseClock.pause(at: CACurrentMediaTime())
    }

    @discardableResult
    public func resume() -> Bool {
        guard stateLock.withLock({ running && !stopping }) else { return false }
        return pauseClock.resume(at: CACurrentMediaTime())
    }

    public var isPaused: Bool { pauseClock.isPaused }

    public var elapsedSeconds: Double {
        pauseClock.elapsed(since: startedAt, at: CACurrentMediaTime())
    }

    public func stop(discarding: Bool = false) async {
        let resources = stateLock.withLock { () -> (SCStream?, ScreenRecordingWriter?)? in
            guard !stopping, stream != nil || writer != nil else { return nil }
            stopping = true
            running = false
            let resources = (stream, writer)
            stream = nil
            writer = nil
            return resources
        }
        guard let resources else { return }
        elapsedTimer?.cancel()
        elapsedTimer = nil
        if let microphone { await microphone.stop() }
        microphone = nil
        if let stream = resources.0 { try? await stream.stopCapture() }
        streamQueue.sync {}
        writerQueue.sync {}
        let pointerTrack = pointer?.stop() ?? ScreenRecordingPointerTrack()
        pointer = nil
        let duration = elapsedSeconds
        let written = await resources.1?.finish(at: duration) == true
        if !pointerTrack.points.isEmpty, let data = try? JSONEncoder().encode(pointerTrack) {
            try? data.write(
                to: ScreenRecordingLibrary.pointerURL(for: take.id, in: directory),
                options: .atomic)
        }
        if discarding || !written {
            ScreenRecordingLibrary.remove(take, from: directory)
        } else {
            var completed = take
            completed.completedAt = Date()
            completed.duration = duration
            completed.pixelWidth = Int(region.pixelSize.width)
            completed.pixelHeight = Int(region.pixelSize.height)
            completed.hasSystemAudio = capturesSystemAudio
            completed.hasMicrophone = capturesMicrophone
            try? ScreenRecordingLibrary.update(completed, in: directory)
            ScreenRecordingLibrary.prune(in: directory, keeping: [take.id])
        }
        stateLock.withLock { stopping = false }
    }

    public func cancel() async {
        await stop(discarding: true)
    }

    private func append(_ sample: CMSampleBuffer, kind: ScreenRecordingWriter.Kind) {
        guard stateLock.withLock({ running && !stopping }) else { return }
        let writer = self.writer
        writerQueue.async { writer?.append(sample, kind: kind) }
    }

    private func startElapsedTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.onElapsedTime?(self.elapsedSeconds)
        }
        elapsedTimer = timer
        timer.resume()
    }

    private static func filter(
        region: ScreenRecordingRegion, content: SCShareableContent
    ) -> SCContentFilter? {
        if let windowID = region.windowID,
            let window = content.windows.first(where: { $0.windowID == windowID })
        {
            return SCContentFilter(desktopIndependentWindow: window)
        }
        guard let display = content.displays.first(where: { $0.displayID == region.displayID })
        else { return nil }
        let processID = NSRunningApplication.current.processIdentifier
        if let application = content.applications.first(where: { $0.processID == processID }) {
            return SCContentFilter(
                display: display, excludingApplications: [application], exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    private static func configuration(
        region: ScreenRecordingRegion, frameRate: Int, capturesSystemAudio: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(region.pixelSize.width) & ~1)
        configuration.height = max(2, Int(region.pixelSize.height) & ~1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.shouldBeOpaque = true
        configuration.scalesToFit = region.windowID != nil
        configuration.preservesAspectRatio = true
        if region.windowID == nil { configuration.sourceRect = region.sourceRect }
        configuration.capturesAudio = capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 6
        return configuration
    }
}

extension ScreenRecordingSession: SCStreamOutput {
    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            append(sampleBuffer, kind: .video)
        case .audio:
            append(sampleBuffer, kind: .systemAudio)
        default:
            break
        }
    }
}

extension ScreenRecordingSession: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stateLock.withLock({ running && !stopping }) else { return }
        stateLock.withLock { running = false }
        onUnexpectedStop?(.captureFailed)
    }
}

private final class ScreenRecordingPauseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var pauses: [ClosedRange<Double>] = []
    private var openPause: Double?

    var isPaused: Bool { lock.withLock { openPause != nil } }

    func pause(at time: Double) -> Bool {
        lock.withLock {
            guard openPause == nil else { return false }
            openPause = time
            return true
        }
    }

    func resume(at time: Double) -> Bool {
        lock.withLock {
            guard let start = openPause else { return false }
            pauses.append(start...max(start, time))
            openPause = nil
            return true
        }
    }

    func elapsed(since origin: Double, at time: Double) -> Double {
        lock.withLock {
            let upper = openPause.map { min(time, $0) } ?? time
            let excluded = pauses.reduce(0.0) {
                $0 + max(0, min(upper, $1.upperBound) - max(origin, $1.lowerBound))
            }
            return max(0, upper - origin - excluded)
        }
    }

    func map(start: Double, duration: Double, origin: Double) -> Double? {
        lock.withLock {
            let end = start + max(0, duration)
            if pauses.contains(where: { start < $0.upperBound && end > $0.lowerBound }) {
                return nil
            }
            if let openPause, end > openPause { return nil }
            let excluded = pauses.reduce(0.0) {
                $0 + max(0, min(start, $1.upperBound) - max(origin, $1.lowerBound))
            }
            return max(0, start - origin - excluded)
        }
    }
}

private final class ScreenRecordingWriter {
    enum Kind { case video, systemAudio, microphone }

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let pauseClock: ScreenRecordingPauseClock
    private var origin: CMTime?
    private var frameCount = 0
    private var failed = false

    init(
        url: URL, size: CGSize, frameRate: Int, systemAudio: Bool,
        microphone: Bool, pauseClock: ScreenRecordingPauseClock
    ) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let width = max(2, Int(size.width) & ~1)
        let height = max(2, Int(size.height) & ~1)
        let bitRate = min(40_000_000, max(3_000_000, width * height * frameRate / 5))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw ScreenRecordingError.writerFailed }
        writer.add(video)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ]
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input); self.systemAudio = input
            } else {
                self.systemAudio = nil
            }
        } else {
            self.systemAudio = nil
        }
        if microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input); self.microphone = input
            } else {
                self.microphone = nil
            }
        } else {
            self.microphone = nil
        }
        self.pauseClock = pauseClock
    }

    func start() -> Bool { writer.startWriting() }

    func append(_ sample: CMSampleBuffer, kind: Kind) {
        guard !failed else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid else { return }
        if origin == nil {
            origin = time
            writer.startSession(atSourceTime: .zero)
        }
        guard let origin else { return }
        let sampleDuration = CMSampleBufferGetDuration(sample)
        let duration = sampleDuration.isValid ? max(0, sampleDuration.seconds) : 0
        guard
            let mapped = pauseClock.map(
                start: time.seconds, duration: duration, origin: origin.seconds),
            let retimed = Self.retimed(
                sample, to: CMTime(seconds: mapped, preferredTimescale: 600_000))
        else { return }
        let input: AVAssetWriterInput? =
            switch kind {
            case .video: video
            case .systemAudio: systemAudio
            case .microphone: microphone
            }
        guard let input, input.isReadyForMoreMediaData else { return }
        if input.append(retimed) {
            if kind == .video { frameCount += 1 }
        } else {
            failed = true
        }
    }

    func finish(at duration: Double) async -> Bool {
        guard frameCount > 0, !failed else { writer.cancelWriting(); return false }
        video.markAsFinished()
        systemAudio?.markAsFinished()
        microphone?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed && duration > 0
    }

    func cancel() { writer.cancelWriting() }

    private static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: time,
            decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &result)
        return status == noErr ? result : nil
    }
}

private final class ScreenRecordingMicrophone: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    var onSample: (@Sendable (CMSampleBuffer) -> Void)?
    private let queue = DispatchQueue(label: "com.pulkit.edith.recorder.microphone")
    private let session = AVCaptureSession()
    private var targetClock: CMClock?

    func start(synchronizingTo clock: CMClock) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let device = AVCaptureDevice.default(for: .audio),
                    let input = try? AVCaptureDeviceInput(device: device)
                else { continuation.resume(returning: false); return }
                let output = AVCaptureAudioDataOutput()
                guard session.canAddInput(input), session.canAddOutput(output)
                else { continuation.resume(returning: false); return }
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
                targetClock = clock
                session.startRunning()
                continuation.resume(returning: session.isRunning)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let sourceClock = session.synchronizationClock, let targetClock else { return }
        let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let target = CMSyncConvertTime(source, from: sourceClock, to: targetClock)
        guard let retimed = Self.retimed(sampleBuffer, to: target) else { return }
        onSample?(retimed)
    }

    private static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: time,
            decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &result)
        return status == noErr ? result : nil
    }
}

private final class ScreenRecordingPointerSampler: @unchecked Sendable {
    private let region: ScreenRecordingRegion
    private let startedAt: Double
    private let pauseClock: ScreenRecordingPauseClock
    private let queue = DispatchQueue(label: "com.pulkit.edith.recorder.pointer")
    private var timer: DispatchSourceTimer?
    private var clickMonitor: Any?
    private var points: [ScreenRecordingPoint] = []
    private var clicks: [ScreenRecordingClick] = []

    init(
        region: ScreenRecordingRegion, startedAt: Double,
        pauseClock: ScreenRecordingPauseClock
    ) {
        self.region = region
        self.startedAt = startedAt
        self.pauseClock = pauseClock
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in self?.sample(click: false) }
        self.timer = timer
        timer.resume()
        DispatchQueue.main.async { [weak self] in
            self?.clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in self?.queue.async { self?.sample(click: true) } }
        }
    }

    func stop() -> ScreenRecordingPointerTrack {
        timer?.cancel()
        timer = nil
        if let clickMonitor { DispatchQueue.main.async { NSEvent.removeMonitor(clickMonitor) } }
        clickMonitor = nil
        return queue.sync { ScreenRecordingPointerTrack(points: points, clicks: clicks) }
    }

    private func sample(click: Bool) {
        guard !pauseClock.isPaused else { return }
        let mouse = NSEvent.mouseLocation
        let rect = region.anchorRect
        guard rect.width > 0, rect.height > 0 else { return }
        let x = min(max((mouse.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((mouse.y - rect.minY) / rect.height, 0), 1)
        let time = pauseClock.elapsed(since: startedAt, at: CACurrentMediaTime())
        points.append(ScreenRecordingPoint(time: time, x: x, y: y))
        if click { clicks.append(ScreenRecordingClick(time: time, x: x, y: y)) }
    }
}
