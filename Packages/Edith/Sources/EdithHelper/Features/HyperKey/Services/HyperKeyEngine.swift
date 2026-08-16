import AppKit
import CoreGraphics
import EdithKit

@MainActor
final class HyperKeyEngine: FeatureModule {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var capsDown = false

    init() {
        _ = installEventTap()
    }

    func shutdown() {
        uninstallEventTap()
    }

    private func installEventTap() -> Bool {
        func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << type.rawValue }
        let mask: CGEventMask = bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let engine = Unmanaged<HyperKeyEngine>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = engine.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passRetained(event)
            }
            return engine.handle(type: type, event: event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func uninstallEventTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
        capsDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged,
            HyperKeyLogic.isCapsLock(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        {
            capsDown = event.flags.contains(.maskAlphaShift)
            return nil
        }
        guard capsDown else { return Unmanaged.passRetained(event) }
        event.flags = HyperKeyLogic.mergedFlags(current: event.flags, hyperActive: true)
        return Unmanaged.passRetained(event)
    }
}
