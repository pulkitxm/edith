import Foundation
import IOKit.ps

struct LidAwakeBatterySnapshot: Equatable, Sendable {
    let percent: Int
    let onAC: Bool
}

final class LidAwakeBatteryMonitor {
    var onChange: ((LidAwakeBatterySnapshot) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let source = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    Unmanaged<LidAwakeBatteryMonitor>.fromOpaque(context)
                        .takeUnretainedValue().emit()
                }, context)?.takeRetainedValue()
        else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        emit()
    }

    func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
    }

    func currentSnapshot() -> LidAwakeBatterySnapshot? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0
            else { continue }
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let percent = Int((Double(current) / Double(maximum)) * 100.0)
            return LidAwakeBatterySnapshot(percent: percent, onAC: onAC)
        }
        return nil
    }

    private func emit() {
        if let snapshot = currentSnapshot() { onChange?(snapshot) }
    }
}
