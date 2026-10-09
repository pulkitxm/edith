import EdithExtensionSupport
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

public final class VirtualCameraPipeline: @unchecked Sendable {
    public typealias FrameOutput = @Sendable (CVPixelBuffer) -> Void

    public struct Statistics: Equatable, Sendable {
        public var framesPerSecond: Double = 0
        public var framesRendered = 0
        public var source: VirtualCameraSource?
        public var sourceWidth = 0
        public var sourceHeight = 0
        public var usingCamera = false
        public var running = false
        public var systemBackgroundActive = false
        public var failureMessage: String?

        public init() {}
    }

    struct Transition {
        let from: VirtualCameraFraming
        let start: TimeInterval
        let duration: TimeInterval
    }

    public static let widthSteps = [1280, 1920, 2560, 3840]
    public static let referenceSize = CGSize(width: 224, height: 126)
    public static let referenceInterval: TimeInterval = 1
    public static let privacyFrameRate = 15.0

    public let queue: DispatchQueue
    private let renderer: VirtualCameraRenderer
    private let analyzer = VirtualCameraAnalyzer()
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private lazy var capture = VirtualCameraCapture(frameQueue: queue)
    private lazy var video = VirtualCameraVideoSource(queue: queue)
    private lazy var screen = VirtualCameraScreenCapture(queue: queue)
    private var state: VirtualCameraState
    private var outputSize: CGSize
    private var frameRate: Int
    private var output: FrameOutput?
    private var running = false
    private var framer = VirtualCameraAutoFramer()
    private var transition: Transition?
    private var effectiveFraming: VirtualCameraFraming
    private var assets = VirtualCameraAssets.none
    private var assetKey: [String?] = []
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var lastLiveBuffer: CVPixelBuffer?
    private var lastLiveMirrored = false
    private var privacyBuffer: CVPixelBuffer?
    private var privacyKey = ""
    private var privacyTimer: DispatchSourceTimer?
    private var frameTimes: [TimeInterval] = []
    private var stats = Statistics()
    private var referenceValue: CGImage?
    private var referenceAt: TimeInterval?
    private var recorder: VirtualCameraRecorder?
    private var videoAudio: ((String, Double, Bool) -> Void)?
    private var screenAudio: ((CMSampleBuffer) -> Void)?
    private var stopAudio: (() -> Void)?
    private var recordingAudioEnabled = false
    private var pendingRecordingAudio = 0

    public init(
        state: VirtualCameraState, outputSize: CGSize, frameRate: Int = 30,
        renderer: VirtualCameraRenderer = VirtualCameraRenderer(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.queue = DispatchQueue(label: "com.pulkit.edith.camera.pipeline", qos: .userInteractive)
        self.renderer = renderer
        self.clock = clock
        self.state = state.sanitized()
        self.outputSize = outputSize
        self.frameRate = frameRate
        self.effectiveFraming = state.composition.framing
        reloadAssets()
    }

    public var statistics: Statistics { lock.withLock { stats } }

    public func setSourceAudio(
        video: @escaping (String, Double, Bool) -> Void, screen: @escaping (CMSampleBuffer) -> Void,
        stop: @escaping () -> Void
    ) {
        queue.async { [weak self] in
            self?.videoAudio = video
            self?.screenAudio = screen
            self?.stopAudio = stop
        }
    }

    public func appendRecordingAudio(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        let accepted = lock.withLock {
            guard recordingAudioEnabled, pendingRecordingAudio < 8 else { return false }
            pendingRecordingAudio += 1
            return true
        }
        guard accepted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.pendingRecordingAudio -= 1 } }
            guard let recorder = self.recorder else { return }
            do { try recorder.appendAudio(buffer, at: time) } catch {
                self.updateStats { $0.failureMessage = error.localizedDescription }
            }
        }
    }

    public func startRecording(to url: URL, audio: Bool = false) throws {
        try queue.sync {
            guard recorder == nil else { throw CocoaError(.fileWriteFileExists) }
            recorder = try VirtualCameraRecorder(url: url, size: outputSize, audio: audio)
            lock.withLock { recordingAudioEnabled = audio }
        }
    }

    public func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let recorder = self.recorder else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile))
                    return
                }
                self.recorder = nil
                self.lock.withLock { self.recordingAudioEnabled = false }
                recorder.finish { continuation.resume(with: $0) }
            }
        }
    }

    private func emit(_ buffer: CVPixelBuffer) {
        if let recorder {
            do { try recorder.append(buffer, at: clock()) } catch {
                updateStats { $0.failureMessage = error.localizedDescription }
            }
        }
        output?(buffer)
    }

    public var reference: CGImage? { lock.withLock { referenceValue } }

    public var currentState: VirtualCameraState { queue.sync { state } }

    public func start(output: @escaping FrameOutput) {
        queue.async { [weak self] in
            guard let self else { return }
            self.output = output
            self.running = true
            self.updateStats { $0.failureMessage = nil }
            self.applyRunMode()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.output = nil
            self.capture.stop()
            self.video.stop()
            self.screen.stop()
            self.stopAudio?()
            self.stopPrivacyTimer()
            self.analyzer.reset()
            self.framer.reset()
            self.transition = nil
            self.updateStats { $0 = Statistics() }
        }
    }

    public func update(state next: VirtualCameraState) {
        queue.async { [weak self] in self?.apply(next.sanitized()) }
    }

    public func update(outputSize next: CGSize, frameRate nextRate: Int) {
        queue.async { [weak self] in
            guard let self, next != self.outputSize || nextRate != self.frameRate else { return }
            self.outputSize = next
            self.frameRate = nextRate
            self.pool = nil
            self.privacyKey = ""
            if self.running { self.applyRunMode() }
        }
    }

    public func process(
        _ pixelBuffer: CVPixelBuffer, at time: TimeInterval, systemBackgroundActive: Bool = false
    ) -> CVPixelBuffer? {
        queue.sync { render(pixelBuffer, at: time, systemBackgroundActive: systemBackgroundActive) }
    }

    public func privacyFrame() -> CVPixelBuffer? {
        queue.sync { makePrivacyFrame() }
    }

    public static func minimumSourceWidth(for state: VirtualCameraState, output: CGSize) -> Int {
        let framing = state.composition.framing
        let zoom = max(framing.zoom, framing.autoFrame == .off ? 1 : 2)
        guard state.sharpZoom else { return Int(output.width) }
        let required = VirtualCameraGeometry.requiredSourceWidth(
            output: output, zoom: zoom, sourceAspect: 16.0 / 9.0)
        return widthSteps.first { $0 >= required } ?? widthSteps[widthSteps.count - 1]
    }

    private func apply(_ next: VirtualCameraState) {
        let previous = state
        state = next
        if next.activeSceneID != previous.activeSceneID, next.transition.duration > 0,
            next.composition.framing != previous.composition.framing
        {
            transition = Transition(
                from: effectiveFraming, start: clock(), duration: next.transition.duration)
        }
        if next.composition.framing.autoFrame != previous.composition.framing.autoFrame {
            framer.reset()
        }
        reloadAssets()
        if next.privacyMessage != previous.privacyMessage || next.privacy != previous.privacy {
            privacyKey = ""
        }
        guard running else { return }
        if next.privacy != previous.privacy || next.media != previous.media {
            applyRunMode()
        } else if next.privacy.usesCamera {
            capture.update(captureConfiguration())
        }
    }

    private func captureConfiguration() -> VirtualCameraCapture.Configuration {
        VirtualCameraCapture.Configuration(
            sourceID: state.sourceID,
            minimumWidth: Self.minimumSourceWidth(for: state, output: outputSize),
            frameRate: Double(frameRate))
    }

    private func applyRunMode() {
        stopAudio?()
        if state.privacy == .stopped {
            video.stop()
            screen.stop()
            capture.stop()
            stopPrivacyTimer()
            analyzer.reset()
            lastLiveBuffer = nil
            privacyBuffer = nil
            updateStats { $0 = Statistics() }
            return
        }
        if state.privacy.usesCamera, state.media.kind == .screen {
            capture.stop()
            video.stop()
            stopPrivacyTimer()
            screen.start(
                state.media, size: outputSize, frameRate: frameRate, audio: screenAudio,
                failed: { [weak self] message in
                    self?.updateStats { $0.failureMessage = message }
                }
            ) { [weak self] buffer in
                self?.handleCapture(buffer, systemBackgroundActive: false)
            }
            updateStats { $0.usingCamera = false }
            return
        }
        screen.stop()
        if state.privacy.usesCamera, state.media.kind == .video {
            capture.stop()
            stopPrivacyTimer()
            video.update(
                state.media, frameRate: frameRate,
                failed: { [weak self] message in
                    self?.updateStats { $0.failureMessage = message }
                }, audio: videoAudio
            ) { [weak self] buffer in
                self?.handleCapture(buffer, systemBackgroundActive: false)
            }
            updateStats { $0.usingCamera = false }
            return
        }
        if state.media.kind == .video {
            video.suspend()
        } else {
            video.stop()
        }
        if state.privacy.usesCamera {
            stopPrivacyTimer()
            if capture.isRunning {
                capture.update(captureConfiguration())
            } else {
                capture.start(
                    captureConfiguration(),
                    failed: { [weak self] message in
                        self?.updateStats { $0.failureMessage = message }
                    }
                ) { [weak self] buffer, _, systemBackground in
                    self?.handleCapture(buffer, systemBackgroundActive: systemBackground)
                }
            }
        } else {
            capture.stop()
            analyzer.reset()
            startPrivacyTimer()
        }
        updateStats { $0.usingCamera = self.state.privacy.usesCamera }
    }

    private func handleCapture(_ buffer: CVPixelBuffer, systemBackgroundActive: Bool) {
        guard running, state.privacy.usesCamera, let output else { return }
        if let rendered = render(
            buffer, at: clock(), systemBackgroundActive: systemBackgroundActive)
        {
            emit(rendered)
        }
        if let active = capture.active {
            updateStats {
                $0.source = active.source
                $0.sourceWidth = active.width
                $0.sourceHeight = active.height
            }
        }
    }

    private func render(
        _ pixelBuffer: CVPixelBuffer, at time: TimeInterval, systemBackgroundActive: Bool
    ) -> CVPixelBuffer? {
        guard state.privacy != .stopped else { return nil }
        updateStats { $0.systemBackgroundActive = systemBackgroundActive }
        let composition = state.composition
        let manual = composition.framing
        var framing = manual
        if let active = transition {
            let progress = (time - active.start) / active.duration
            if progress >= 1 {
                transition = nil
            } else {
                framing = VirtualCameraGeometry.interpolate(active.from, manual, progress: progress)
            }
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = VirtualCameraRenderer.oriented(image, framing: manual)
        let wantsMask = composition.background.needsSegmentation && !systemBackgroundActive
        let wantsFaces = manual.autoFrame != .off
        analyzer.submit(oriented, wantsMask: wantsMask, wantsFaces: wantsFaces)
        let analysis = analyzer.latest()
        if wantsFaces {
            framing = framer.update(
                faces: analysis.faces, mode: manual.autoFrame, manual: framing,
                source: oriented.extent.size, output: outputSize, at: time)
        }
        effectiveFraming = framing
        let input = VirtualCameraFrameInput(
            image: image, composition: composition, framing: framing,
            mask: wantsMask ? analysis.mask : nil, date: Date(), assets: assets,
            systemBackgroundActive: systemBackgroundActive)
        var composed = renderer.compose(input, output: outputSize)
        if state.mirrorOutput {
            composed = VirtualCameraRenderer.oriented(
                composed, framing: VirtualCameraFraming(flipHorizontal: true))
        }
        if referenceAt.map({ time - $0 >= Self.referenceInterval || time < $0 }) ?? true {
            referenceAt = time
            let small = renderer.cgImage(
                renderer.framedReference(input, output: Self.referenceSize),
                size: Self.referenceSize)
            lock.withLock { referenceValue = small }
        }
        guard let buffer = makeBuffer() else { return nil }
        renderer.render(composed, into: buffer)
        lastLiveBuffer = buffer
        lastLiveMirrored = state.mirrorOutput
        recordFrame(at: time)
        return buffer
    }

    private func recordFrame(at time: TimeInterval) {
        frameTimes.append(time)
        frameTimes.removeAll { time - $0 > 1 }
        let fps = Double(frameTimes.count)
        updateStats {
            $0.framesRendered += 1
            $0.failureMessage = nil
            $0.framesPerSecond = fps
            $0.running = true
        }
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil || poolSize != outputSize {
            poolSize = outputSize
            pool = Self.makePool(width: Int(outputSize.width), height: Int(outputSize.height))
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    public static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private func reloadAssets() {
        let composition = state.composition
        let key: [String?] = [
            composition.overlays.logo.isVisible ? composition.overlays.logo.imagePath : nil,
            composition.background.mode == .image ? composition.background.imagePath : nil,
        ]
        guard key != assetKey else { return }
        assetKey = key
        assets = VirtualCameraAssets.load(for: composition)
    }

    private func makePrivacyFrame() -> CVPixelBuffer? {
        guard state.privacy != .stopped else { return nil }
        if state.privacy == .freeze, let lastLiveBuffer {
            guard lastLiveMirrored != state.mirrorOutput else { return lastLiveBuffer }
            guard let buffer = makeBuffer() else { return nil }
            let image = VirtualCameraRenderer.oriented(
                CIImage(cvPixelBuffer: lastLiveBuffer),
                framing: VirtualCameraFraming(flipHorizontal: true))
            renderer.render(image, into: buffer)
            self.lastLiveBuffer = buffer
            lastLiveMirrored = state.mirrorOutput
            return buffer
        }
        let key =
            "\(state.privacy.rawValue)|\(state.privacyMessage)|\(outputSize)|\(state.mirrorOutput)"
        if key == privacyKey, let privacyBuffer { return privacyBuffer }
        let backdrop = lastLiveBuffer.map {
            VirtualCameraRenderer.oriented(
                CIImage(cvPixelBuffer: $0),
                framing: VirtualCameraFraming(flipHorizontal: lastLiveMirrored))
        }
        var image = renderer.privacyImage(
            state.privacy, message: state.privacyMessage, backdrop: backdrop, output: outputSize)
        if state.mirrorOutput {
            image = VirtualCameraRenderer.oriented(
                image, framing: VirtualCameraFraming(flipHorizontal: true))
        }
        guard let buffer = makeBuffer() else { return nil }
        renderer.render(image, into: buffer)
        privacyBuffer = buffer
        privacyKey = key
        return buffer
    }

    private func startPrivacyTimer() {
        guard privacyTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(), repeating: 1 / Self.privacyFrameRate, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.running, !self.state.privacy.usesCamera, let output = self.output,
                let frame = self.makePrivacyFrame()
            else { return }
            self.emit(frame)
        }
        timer.resume()
        privacyTimer = timer
    }

    private func stopPrivacyTimer() {
        privacyTimer?.cancel()
        privacyTimer = nil
    }

    private func updateStats(_ change: (inout Statistics) -> Void) {
        lock.withLock { change(&stats) }
    }
}
