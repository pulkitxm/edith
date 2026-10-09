import EdithExtensionSupport
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public final class VirtualCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    public typealias FrameHandler = (CVPixelBuffer, CMTime, Bool) -> Void

    public struct Configuration: Equatable, Sendable {
        public var sourceID: String?
        public var minimumWidth: Int
        public var frameRate: Double

        public init(sourceID: String?, minimumWidth: Int, frameRate: Double = 30) {
            self.sourceID = sourceID
            self.minimumWidth = minimumWidth
            self.frameRate = frameRate
        }
    }

    public struct Active: Equatable, Sendable {
        public var source: VirtualCameraSource
        public var width: Int
        public var height: Int
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.pulkit.edith.camera.session")
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var handler: FrameHandler?
    private var failureHandler: (@Sendable (String) -> Void)?
    private var configuration: Configuration?
    private var input: AVCaptureDeviceInput?
    private var activeValue: Active?
    private var chosenFormat: AVCaptureDevice.Format?
    private var disconnectObserver: NSObjectProtocol?

    public init(frameQueue: DispatchQueue) {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            self?.deviceDisconnected(device.uniqueID)
        }
    }

    deinit {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }

    public var active: Active? {
        lock.withLock { activeValue }
    }

    public var isRunning: Bool {
        lock.withLock { handler != nil }
    }

    public func start(
        _ configuration: Configuration, failed: @escaping @Sendable (String) -> Void,
        handler: @escaping FrameHandler
    ) {
        lock.withLock {
            self.handler = handler
            self.failureHandler = failed
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.apply(configuration) else { return }
            if !self.session.isRunning {
                self.session.startRunning()
                self.reassertFormat()
            }
        }
    }

    public func update(_ configuration: Configuration) {
        guard isRunning else { return }
        sessionQueue.async { [weak self] in _ = self?.apply(configuration) }
    }

    public func stop() {
        lock.withLock {
            handler = nil
            failureHandler = nil
            activeValue = nil
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            if let input = self.input { self.session.removeInput(input) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
            self.input = nil
            self.configuration = nil
            self.chosenFormat = nil
        }
    }

    public func shutdown() async {
        stop()
        await withCheckedContinuation { continuation in
            sessionQueue.async { continuation.resume() }
        }
    }

    private func deviceDisconnected(_ id: String) {
        sessionQueue.async { [weak self] in
            guard let self, self.input?.device.uniqueID == id,
                let configuration = self.configuration
            else { return }
            self.input.map { self.session.removeInput($0) }
            self.input = nil
            self.configuration = nil
            _ = self.apply(configuration)
        }
    }

    private func apply(_ next: Configuration) -> Bool {
        guard lock.withLock({ handler != nil }) else { return false }
        guard next != configuration || input == nil else { return true }
        guard let device = VirtualCameraDevices.device(for: next.sourceID) else {
            fail(
                "The selected camera is no longer available. Reconnect it or choose another camera."
            )
            return false
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if input?.device.uniqueID != device.uniqueID {
            if let input { session.removeInput(input) }
            let replacement: AVCaptureDeviceInput
            do {
                replacement = try AVCaptureDeviceInput(device: device)
            } catch {
                input = nil
                fail(error.localizedDescription)
                return false
            }
            guard session.canAddInput(replacement) else {
                input = nil
                fail("The camera could not be opened. Close other camera apps and try again.")
                return false
            }
            session.addInput(replacement)
            input = replacement
        }
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else {
                fail("The camera output could not be configured. Try reconnecting the camera.")
                return false
            }
            session.addOutput(output)
        }
        let options = VirtualCameraDevices.formatOptions(for: device)
        if let choice = VirtualCameraFormatChooser.choose(
            options, minimumWidth: next.minimumWidth, frameRate: next.frameRate),
            device.formats.indices.contains(choice.index)
        {
            chosenFormat = device.formats[choice.index]
            guard configure(device, format: device.formats[choice.index], frameRate: next.frameRate)
            else { return false }
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription)
        lock.withLock {
            activeValue = Active(
                source: VirtualCameraDevices.source(for: device), width: Int(dimensions.width),
                height: Int(dimensions.height))
        }
        configuration = next
        return true
    }

    private func fail(_ message: String) {
        let failed = lock.withLock {
            activeValue = nil
            return failureHandler
        }
        failed?(message)
    }

    private func reassertFormat() {
        guard let device = input?.device, let desired = chosenFormat,
            device.activeFormat != desired, let configuration
        else { return }
        _ = configure(device, format: desired, frameRate: configuration.frameRate)
    }

    private func configure(
        _ device: AVCaptureDevice, format: AVCaptureDevice.Format, frameRate: Double
    ) -> Bool {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.activeFormat != format { device.activeFormat = format }
            let supportsRate = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= frameRate && frameRate <= $0.maxFrameRate
            }
            if supportsRate {
                let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = sampleBuffer.imageBuffer,
            let handler = lock.withLock({ handler })
        else { return }
        let systemBackgroundActive: Bool
        if #available(macOS 15.0, *) {
            let input = connection.inputPorts.first?.input as? AVCaptureDeviceInput
            systemBackgroundActive = input?.device.isBackgroundReplacementActive == true
        } else {
            systemBackgroundActive = false
        }
        handler(pixelBuffer, sampleBuffer.presentationTimeStamp, systemBackgroundActive)
    }
}
