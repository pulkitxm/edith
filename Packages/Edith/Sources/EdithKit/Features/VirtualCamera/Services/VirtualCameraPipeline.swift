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

        public init() {}
    }

    struct Transition {
        let from: VirtualCameraFraming
        let start: TimeInterval
        let duration: TimeInterval
    }

    public static let widthSteps = [1280, 1920, 2560, 3840]
    public static let privacyFrameRate = 15.0

    public let queue: DispatchQueue
    private let renderer: VirtualCameraRenderer
    private let analyzer = VirtualCameraAnalyzer()
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private lazy var capture = VirtualCameraCapture(frameQueue: queue)
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
    private var privacyBuffer: CVPixelBuffer?
    private var privacyKey = ""
    private var privacyTimer: DispatchSourceTimer?
    private var frameTimes: [TimeInterval] = []
    private var stats = Statistics()

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

    public var currentState: VirtualCameraState { queue.sync { state } }

    public func start(output: @escaping FrameOutput) {
        queue.async { [weak self] in
            guard let self else { return }
            self.output = output
            self.running = true
            self.applyRunMode()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.output = nil
            self.capture.stop()
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

    public func process(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) -> CVPixelBuffer? {
        queue.sync { render(pixelBuffer, at: time) }
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
        if next.privacy.usesCamera != previous.privacy.usesCamera {
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
        if state.privacy.usesCamera {
            stopPrivacyTimer()
            if capture.isRunning {
                capture.update(captureConfiguration())
            } else {
                capture.start(captureConfiguration()) { [weak self] buffer, _ in
                    self?.handleCapture(buffer)
                }
            }
        } else {
            capture.stop()
            analyzer.reset()
            startPrivacyTimer()
        }
        updateStats { $0.usingCamera = self.state.privacy.usesCamera }
    }

    private func handleCapture(_ buffer: CVPixelBuffer) {
        guard running, state.privacy.usesCamera, let output else { return }
        if let rendered = render(buffer, at: clock()) {
            output(rendered)
        }
        if let active = capture.active {
            updateStats {
                $0.source = active.source
                $0.sourceWidth = active.width
                $0.sourceHeight = active.height
            }
        }
    }

    private func render(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) -> CVPixelBuffer? {
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
        let wantsMask = composition.background.needsSegmentation
        let wantsFaces = manual.autoFrame != .off
        analyzer.submit(oriented, wantsMask: wantsMask, wantsFaces: wantsFaces)
        let analysis = analyzer.latest()
        if wantsFaces {
            framing = framer.update(
                faces: analysis.faces, mode: manual.autoFrame, manual: framing,
                source: oriented.extent.size, output: outputSize, at: time)
        }
        effectiveFraming = framing
        let composed = renderer.compose(
            VirtualCameraFrameInput(
                image: image, composition: composition, framing: framing,
                mask: wantsMask ? analysis.mask : nil, date: Date(), assets: assets),
            output: outputSize)
        guard let buffer = makeBuffer() else { return nil }
        renderer.render(composed, into: buffer)
        lastLiveBuffer = buffer
        recordFrame(at: time)
        return buffer
    }

    private func recordFrame(at time: TimeInterval) {
        frameTimes.append(time)
        frameTimes.removeAll { time - $0 > 1 }
        let fps = Double(frameTimes.count)
        updateStats {
            $0.framesRendered += 1
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
        if state.privacy == .freeze, let lastLiveBuffer { return lastLiveBuffer }
        let key = "\(state.privacy.rawValue)|\(state.privacyMessage)|\(outputSize)"
        if key == privacyKey, let privacyBuffer { return privacyBuffer }
        let backdrop = lastLiveBuffer.map { CIImage(cvPixelBuffer: $0) }
        let image = renderer.privacyImage(
            state.privacy, message: state.privacyMessage, backdrop: backdrop, output: outputSize)
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
            output(frame)
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
