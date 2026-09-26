import CoreMedia
import CoreMediaIO
import CoreVideo
import EdithCameraSupport
import Foundation

public struct VirtualCameraListener: @unchecked Sendable {
    let remove: () -> Void

    public init(remove: @escaping () -> Void) {
        self.remove = remove
    }
}

public protocol VirtualCameraHardware: Sendable {
    func deviceIDs() -> [CMIOObjectID]
    func string(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String?
    func streamIDs(_ device: CMIOObjectID) -> [CMIOStreamID]
    func direction(_ stream: CMIOStreamID) -> UInt32?
    func flag(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> Bool?
    func startSink(device: CMIOObjectID, stream: CMIOStreamID) -> CMSimpleQueue?
    func stopSink(device: CMIOObjectID, stream: CMIOStreamID)
    func listen(
        _ object: CMIOObjectID, selector: CMIOObjectPropertySelector, queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> VirtualCameraListener?
}

public struct VirtualCameraEndpoints: Equatable, Sendable {
    public let device: CMIOObjectID
    public let source: CMIOStreamID?
    public let sink: CMIOStreamID?
}

public enum VirtualCameraLocator {
    public static let sinkDirection: UInt32 = 0
    public static let sourceDirection: UInt32 = 1

    public static func find(uid: String, hardware: VirtualCameraHardware) -> VirtualCameraEndpoints?
    {
        let uidSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
        guard
            let device = hardware.deviceIDs().first(where: {
                hardware.string($0, selector: uidSelector) == uid
            })
        else { return nil }
        let streams = hardware.streamIDs(device)
        let directions = streams.map { hardware.direction($0) }
        var source = zip(streams, directions).first { $0.1 == sourceDirection }?.0
        var sink = zip(streams, directions).first { $0.1 == sinkDirection }?.0
        if source == nil, sink == nil, streams.count >= 2 {
            source = streams[0]
            sink = streams[1]
        }
        return VirtualCameraEndpoints(device: device, source: source, sink: sink)
    }

    public static func status(
        at endpoints: VirtualCameraEndpoints, hardware: VirtualCameraHardware
    ) -> VirtualCameraExtensionStatus? {
        let selector = CMIOObjectPropertySelector(VirtualCameraProperty.statusCode)
        for object in [endpoints.source, endpoints.device].compactMap({ $0 }) {
            if let text = hardware.string(object, selector: selector),
                let status = VirtualCameraExtensionStatus.decode(text)
            {
                return status
            }
        }
        return nil
    }
}

public struct VirtualCameraSystemHardware: VirtualCameraHardware {
    public init() {}

    static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    func objects(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var values = [CMIOObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard
            CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &values) == noErr
        else { return [] }
        return Array(values.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    public func deviceIDs() -> [CMIOObjectID] {
        objects(
            CMIOObjectID(kCMIOObjectSystemObject),
            selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
    }

    public func streamIDs(_ device: CMIOObjectID) -> [CMIOStreamID] {
        objects(device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
    }

    public func string(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0
        else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(
                object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used,
                pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    public func startSink(device: CMIOObjectID, stream: CMIOStreamID) -> CMSimpleQueue? {
        var unmanaged: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &unmanaged) == noErr,
            let unmanaged
        else { return nil }
        let queue = unmanaged.takeRetainedValue()
        guard CMIODeviceStartStream(device, stream) == noErr else { return nil }
        return queue
    }

    public func stopSink(device: CMIOObjectID, stream: CMIOStreamID) {
        CMIODeviceStopStream(device, stream)
    }

    public func listen(
        _ object: CMIOObjectID, selector: CMIOObjectPropertySelector, queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> VirtualCameraListener? {
        var address = Self.address(selector)
        let block: CMIOObjectPropertyListenerBlock = { _, _ in handler() }
        guard CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else {
            return nil
        }
        return VirtualCameraListener {
            var address = Self.address(selector)
            CMIOObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }

    public func flag(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> Bool? {
        var address = Self.address(selector)
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard
            CMIOObjectGetPropertyData(
                object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
                == noErr
        else { return nil }
        return value != 0
    }

    public func direction(_ stream: CMIOStreamID) -> UInt32? {
        var address = Self.address(CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard
            CMIOObjectGetPropertyData(
                stream, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
        else { return nil }
        return value
    }
}

public final class VirtualCameraSink: @unchecked Sendable {
    public let deviceUID: String
    private let hardware: VirtualCameraHardware
    private let lock = NSLock()
    private var endpoints: VirtualCameraEndpoints?
    private var queue: CMSimpleQueue?
    private var listeners: [VirtualCameraListener] = []
    private let listenerQueue = DispatchQueue(label: "com.pulkit.edith.camera.cmio")

    public init(deviceUID: String, hardware: VirtualCameraHardware = VirtualCameraSystemHardware())
    {
        self.deviceUID = deviceUID
        self.hardware = hardware
    }

    public convenience init(
        extensionIdentifier: String,
        hardware: VirtualCameraHardware = VirtualCameraSystemHardware()
    ) {
        self.init(
            deviceUID: VirtualCameraIdentity.deviceID(forExtension: extensionIdentifier).uuidString,
            hardware: hardware)
    }

    public var isRunningSomewhere: Bool {
        guard let device = locate()?.device else { return false }
        return hardware.flag(
            device,
            selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            == true
    }

    public func locate() -> VirtualCameraEndpoints? {
        VirtualCameraLocator.find(uid: deviceUID, hardware: hardware)
    }

    public var isInstalled: Bool { locate() != nil }

    public var isConnected: Bool { lock.withLock { queue != nil } }

    public func status() -> VirtualCameraExtensionStatus? {
        guard let endpoints = lock.withLock({ self.endpoints }) ?? locate() else { return nil }
        return VirtualCameraLocator.status(at: endpoints, hardware: hardware)
    }

    @discardableResult
    public func connect() -> Bool {
        if isConnected { return true }
        guard let found = locate(), let sink = found.sink,
            let bufferQueue = hardware.startSink(device: found.device, stream: sink)
        else { return false }
        lock.withLock {
            endpoints = found
            queue = bufferQueue
        }
        return true
    }

    @discardableResult
    public func send(_ pixelBuffer: CVPixelBuffer, frameRate: Int) -> Bool {
        guard let queue = lock.withLock({ self.queue }) else { return false }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue),
            let sample = VirtualCameraSampleBuffer.make(
                pixelBuffer: pixelBuffer, presentationTime: VirtualCameraSampleBuffer.now(),
                frameRate: frameRate)
        else { return false }
        let element = Unmanaged.passRetained(sample).toOpaque()
        guard CMSimpleQueueEnqueue(queue, element: element) == noErr else {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            return false
        }
        return true
    }

    public func disconnect() {
        let current = lock.withLock { () -> VirtualCameraEndpoints? in
            let current = endpoints
            endpoints = nil
            queue = nil
            return current
        }
        if let current, let sink = current.sink {
            hardware.stopSink(device: current.device, stream: sink)
        }
    }

    public func observe(_ onChange: @escaping @Sendable () -> Void) {
        stopObserving()
        var targets: [(CMIOObjectID, CMIOObjectPropertySelector)] = [
            (
                CMIOObjectID(kCMIOObjectSystemObject),
                CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
            )
        ]
        if let found = locate() {
            let status = CMIOObjectPropertySelector(VirtualCameraProperty.statusCode)
            targets.append((found.device, status))
            targets.append(
                (
                    found.device,
                    CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
                ))
            if let source = found.source { targets.append((source, status)) }
        }
        let installed = targets.compactMap { object, selector in
            hardware.listen(object, selector: selector, queue: listenerQueue, handler: onChange)
        }
        lock.withLock { listeners = installed }
    }

    public var listenerCount: Int { lock.withLock { listeners.count } }

    public func stopObserving() {
        let current = lock.withLock { () -> [VirtualCameraListener] in
            let current = listeners
            listeners = []
            return current
        }
        current.forEach { $0.remove() }
    }

    deinit {
        stopObserving()
        disconnect()
    }
}
