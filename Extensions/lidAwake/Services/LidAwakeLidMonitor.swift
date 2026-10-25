import Foundation
import IOKit
import IOKit.pwr_mgt

private let lidAwakeClamshellStateChangeMessage =
    (UInt32(0x38) << 26) | (UInt32(13) << 14) | UInt32(0x100)

final class LidAwakeLidMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isClosed: Bool?

    private var rootDomain: io_service_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL

    func start() {
        guard notificationPort == nil else { return }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            IOObjectRelease(service)
            return
        }
        rootDomain = service
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            { context, _, messageType, _ in
                guard messageType == lidAwakeClamshellStateChangeMessage,
                    let context
                else { return }
                Unmanaged<LidAwakeLidMonitor>.fromOpaque(context)
                    .takeUnretainedValue().emitCurrentState()
            },
            context,
            &notifier)
        guard result == kIOReturnSuccess else {
            stop()
            return
        }
        emitCurrentState()
    }

    func stop() {
        if notifier != IO_OBJECT_NULL {
            IOObjectRelease(notifier)
            notifier = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if rootDomain != IO_OBJECT_NULL {
            IOObjectRelease(rootDomain)
            rootDomain = IO_OBJECT_NULL
        }
        isClosed = nil
    }

    deinit { stop() }

    private func emitCurrentState() {
        guard rootDomain != IO_OBJECT_NULL,
            let property = IORegistryEntryCreateCFProperty(
                rootDomain,
                kAppleClamshellStateKey as CFString,
                kCFAllocatorDefault,
                0)?.takeRetainedValue() as? NSNumber
        else { return }
        let closed = property.boolValue
        guard closed != isClosed else { return }
        isClosed = closed
        onChange?(closed)
    }
}
