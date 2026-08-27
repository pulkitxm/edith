import AppKit
import Darwin
import Foundation
import IOKit

final class TrackpadContactMonitor: @unchecked Sendable {
    struct Snapshot: Sendable {
        let fingerCount: Int
        let frameAge: TimeInterval
        let settledFor: TimeInterval
    }

    static let shared = TrackpadContactMonitor()

    private let lock = NSLock()
    private var fingerCount = 0
    private var lastFrameUptime: TimeInterval = 0
    private var threeFingersSince: TimeInterval?
    private var deviceList: CFArray?
    private var wakeObserver: Any?
    private var hotplugPort: IONotificationPortRef?
    private var hotplugIterator: io_iterator_t = 0

    var isAvailable: Bool { MouseMultitouchBridge.isAvailable }

    func start() {
        guard MouseMultitouchBridge.isAvailable else { return }
        startDevices()
        installWakeObserver()
        installHotplugObserver()
    }

    func stop() {
        stopDevices()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if hotplugIterator != 0 {
            IOObjectRelease(hotplugIterator)
            hotplugIterator = 0
        }
        if let hotplugPort {
            IONotificationPortDestroy(hotplugPort)
            self.hotplugPort = nil
        }
        resetContacts()
    }

    func snapshot(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            fingerCount: fingerCount,
            frameAge: now - lastFrameUptime,
            settledFor: threeFingersSince.map { now - $0 } ?? 0)
    }

    fileprivate func receive(fingerCount count: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if count == 3 {
            if fingerCount != 3 { threeFingersSince = now }
        } else {
            threeFingersSince = nil
        }
        fingerCount = count
        lastFrameUptime = now
        lock.unlock()
    }

    private func startDevices() {
        guard deviceList == nil, let list = MouseMultitouchBridge.deviceList() else { return }
        deviceList = list
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            MouseMultitouchBridge.register(pointer, mouseTrackpadContactCallback)
            MouseMultitouchBridge.start(pointer)
        }
    }

    private func stopDevices() {
        guard let list = deviceList else { return }
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            MouseMultitouchBridge.stop(pointer)
            MouseMultitouchBridge.register(pointer, nil)
        }
        deviceList = nil
    }

    private func restartDevices() {
        stopDevices()
        resetContacts()
        startDevices()
    }

    private func resetContacts() {
        lock.lock()
        fingerCount = 0
        lastFrameUptime = 0
        threeFingersSince = nil
        lock.unlock()
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.restartDevices()
        }
    }

    private func installHotplugObserver() {
        guard hotplugPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
            { context, iterator in
                while case let entry = IOIteratorNext(iterator), entry != 0 {
                    IOObjectRelease(entry)
                }
                guard let context else { return }
                Unmanaged<TrackpadContactMonitor>.fromOpaque(context).takeUnretainedValue()
                    .restartDevices()
            }, context, &iterator)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            IOObjectRelease(entry)
        }
        hotplugPort = port
        hotplugIterator = iterator
    }
}

private func mouseTrackpadContactCallback(
    _: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?, _ count: Int32, _: Double, _: Int32
) -> Int32 {
    TrackpadContactMonitor.shared.receive(fingerCount: Int(count))
    return 0
}

private enum MouseMultitouchBridge {
    typealias ContactCallback =
        @convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
        ) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register =
        @convention(c) (
            UnsafeMutableRawPointer, ContactCallback?
        ) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        RTLD_NOW)
    private static let createList: CreateList? = symbol("MTDeviceCreateList")
    private static let register: Register? = symbol("MTRegisterContactFrameCallback")
    private static let start: Start? = symbol("MTDeviceStart")
    private static let stop: Stop? = symbol("MTDeviceStop")

    static var isAvailable: Bool {
        createList != nil && register != nil && start != nil && stop != nil
    }

    static func deviceList() -> CFArray? {
        guard let createList, let unmanaged = createList() else { return nil }
        let list = unmanaged.takeRetainedValue()
        guard CFArrayGetCount(list) > 0 else {
            return nil
        }
        return list
    }

    static func register(_ device: UnsafeMutableRawPointer, _ callback: ContactCallback?) {
        register?(device, callback)
    }

    static func start(_ device: UnsafeMutableRawPointer) {
        start?(device, 0)
    }

    static func stop(_ device: UnsafeMutableRawPointer) {
        stop?(device)
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
