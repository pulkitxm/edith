import CoreMedia
import CoreMediaIO
import CoreVideo
import EdithCameraSupport
import Foundation
import VideoToolbox
import os

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    static let statusProperty = CMIOExtensionProperty(rawValue: VirtualCameraProperty.statusKey)
    static let virtualTransport = 0x7669_7274

    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStreamSource!
    private var sink: CameraStreamSource!
    private let build: String
    private let logger: Logger
    private let queue = DispatchQueue(label: "com.pulkit.edith.camera.relay", qos: .userInteractive)
    private let lock = NSLock()
    private var relay = VirtualCameraRelay()
    private var format = VirtualCameraFormat.standard
    private var placeholders: [VirtualCameraRelay.Feed: CVPixelBuffer] = [:]
    private var ticker: DispatchSourceTimer?
    private var sinkGeneration = 0
    private var transfer: VTPixelTransferSession?
    private var scaledPool: CVPixelBufferPool?
    private var publishedStatus: VirtualCameraExtensionStatus?
    private var clientsObservation: NSKeyValueObservation?

    init(extensionIdentifier: String, localizedName: String, build: String) {
        self.build = build
        logger = Logger(subsystem: extensionIdentifier, category: "device")
        super.init()
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: VirtualCameraIdentity.deviceID(forExtension: extensionIdentifier),
            legacyDeviceID: nil, source: self)
        let formats = VirtualCameraFormat.supported.compactMap(Self.streamFormat)
        source = CameraStreamSource(
            localizedName: localizedName + " Video",
            streamID: VirtualCameraIdentity.sourceStreamID(forExtension: extensionIdentifier),
            direction: .source, formats: formats, owner: self)
        sink = CameraStreamSource(
            localizedName: localizedName + " Input",
            streamID: VirtualCameraIdentity.sinkStreamID(forExtension: extensionIdentifier),
            direction: .sink, formats: formats, owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            logger.error("could not add camera streams: \(error.localizedDescription)")
        }
        clientsObservation = source.stream.observe(\.streamingClients, options: [.new]) {
            [weak self] _, _ in
            self?.consumersChanged()
        }
    }

    static func streamFormat(_ format: VirtualCameraFormat) -> CMIOExtensionStreamFormat? {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(format.width), height: Int32(format.height), extensions: nil,
            formatDescriptionOut: &description)
        guard let description else { return nil }
        let duration = CMTime(value: 1, timescale: CMTimeScale(format.frameRate))
        return CMIOExtensionStreamFormat(
            formatDescription: description, maxFrameDuration: duration,
            minFrameDuration: duration, validFrameDurations: nil)
    }

    var activeFormat: VirtualCameraFormat {
        lock.withLock { format }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, Self.statusProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = Self.virtualTransport
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = VirtualCameraIdentity.model
        }
        if properties.contains(Self.statusProperty) {
            deviceProperties.setPropertyState(statusState(), forProperty: Self.statusProperty)
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func statusState() -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(value: currentStatus().encoded() as NSString)
    }

    func currentStatus() -> VirtualCameraExtensionStatus {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock {
            VirtualCameraExtensionStatus(
                build: build, clients: relay.clientNames, format: format,
                receivingFrames: relay.isReceivingFrames(at: now))
        }
    }

    func selectFormat(at index: Int) {
        lock.withLock {
            format = VirtualCameraFormat.format(at: index)
            placeholders = [:]
            scaledPool = nil
        }
        queue.async { [weak self] in self?.publishStatus() }
    }

    func consumersChanged() {
        queue.async { [weak self] in self?.refreshConsumers() }
        for delay in [100, 500] {
            queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                self?.refreshConsumers()
            }
        }
    }

    private func refreshConsumers() {
        let clients = source.stream.streamingClients.map {
            (id: $0.clientID, signingID: $0.signingID)
        }
        let changed = lock.withLock { relay.setConsumers(clients) }
        let hasConsumers = lock.withLock { relay.hasConsumers }
        if hasConsumers { startTicker() } else { stopTicker() }
        if changed { publishStatus() }
    }

    func sinkStarted(client: CMIOExtensionClient) {
        queue.async { [weak self] in
            guard let self else { return }
            let generation = self.lock.withLock {
                self.relay.sinkStarted()
                self.sinkGeneration += 1
                return self.sinkGeneration
            }
            self.publishStatus()
            self.consume(client: client, generation: generation)
        }
    }

    func sinkStopped() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.relay.sinkStopped()
                self.sinkGeneration += 1
            }
            self.publishStatus()
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLock { sinkGeneration == generation }
    }

    private func consume(client: CMIOExtensionClient, generation: Int) {
        guard isCurrent(generation) else { return }
        sink.stream.consumeSampleBuffer(from: client) {
            [weak self] sample, sequence, _, _, error in
            self?.queue.async { [weak self] in
                self?.received(
                    sample, sequence: sequence, failed: error != nil, client: client,
                    generation: generation)
            }
        }
    }

    private func received(
        _ sample: CMSampleBuffer?, sequence: UInt64, failed: Bool, client: CMIOExtensionClient,
        generation: Int
    ) {
        guard isCurrent(generation) else { return }
        if let sample {
            forward(sample, sequence: sequence)
            consume(client: client, generation: generation)
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(failed ? 100 : 5)) { [weak self] in
            self?.consume(client: client, generation: generation)
        }
    }

    private func forward(_ sample: CMSampleBuffer, sequence: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let (wasLive, hasConsumers) = lock.withLock {
            let wasLive = relay.isReceivingFrames(at: now)
            relay.frameArrived(at: now)
            return (wasLive, relay.hasConsumers)
        }
        let hostTime = VirtualCameraSampleBuffer.hostTimeNanoseconds(
            VirtualCameraSampleBuffer.now())
        sink.stream.notifyScheduledOutputChanged(
            CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: hostTime))
        if hasConsumers, let output = conformed(sample) {
            source.stream.send(
                output, discontinuity: [],
                hostTimeInNanoseconds: VirtualCameraSampleBuffer.hostTimeNanoseconds(
                    output.presentationTimeStamp))
        }
        if !wasLive { publishStatus() }
    }

    private func conformed(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let image = sample.imageBuffer else { return nil }
        let target = activeFormat
        if CVPixelBufferGetWidth(image) == target.width,
            CVPixelBufferGetHeight(image) == target.height
        {
            return sample
        }
        guard let scaled = scale(image, to: target) else { return nil }
        return VirtualCameraSampleBuffer.make(
            pixelBuffer: scaled, presentationTime: sample.presentationTimeStamp,
            frameRate: target.frameRate)
    }

    private func scale(_ image: CVPixelBuffer, to target: VirtualCameraFormat) -> CVPixelBuffer? {
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            if let session {
                VTSessionSetProperty(
                    session, key: kVTPixelTransferPropertyKey_ScalingMode,
                    value: kVTScalingMode_Letterbox)
            }
            transfer = session
        }
        let pool = lock.withLock { () -> CVPixelBufferPool? in
            if scaledPool == nil { scaledPool = Self.makePool(for: target) }
            return scaledPool
        }
        guard let transfer, let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output,
            VTPixelTransferSessionTransferImage(transfer, from: image, to: output) == noErr
        else { return nil }
        return output
    }

    static func makePool(for format: VirtualCameraFormat) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = Double(activeFormat.frameDurationNanoseconds) / 1_000_000_000
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let (needsPlaceholder, feed) = lock.withLock {
            (relay.needsPlaceholder(at: now), relay.feed(at: now))
        }
        if needsPlaceholder, let buffer = placeholder(for: feed) {
            let target = activeFormat
            if let sample = VirtualCameraSampleBuffer.make(
                pixelBuffer: buffer, presentationTime: VirtualCameraSampleBuffer.now(),
                frameRate: target.frameRate)
            {
                source.stream.send(
                    sample, discontinuity: [],
                    hostTimeInNanoseconds: VirtualCameraSampleBuffer.hostTimeNanoseconds(
                        sample.presentationTimeStamp))
            }
        }
        publishStatus()
    }

    private func placeholder(for feed: VirtualCameraRelay.Feed) -> CVPixelBuffer? {
        if let cached = lock.withLock({ placeholders[feed] }) { return cached }
        let target = activeFormat
        guard
            let buffer = VirtualCameraPlaceholder.makeBuffer(
                width: target.width, height: target.height)
        else { return nil }
        VirtualCameraPlaceholder.render(VirtualCameraPlaceholder.card(for: feed), into: buffer)
        lock.withLock { placeholders[feed] = buffer }
        return buffer
    }

    private func publishStatus() {
        let status = currentStatus()
        guard status != publishedStatus else { return }
        publishedStatus = status
        let state = CMIOExtensionPropertyState<AnyObject>(value: status.encoded() as NSString)
        device.notifyPropertiesChanged([Self.statusProperty: state])
        source.stream.notifyPropertiesChanged([Self.statusProperty: state])
    }
}
