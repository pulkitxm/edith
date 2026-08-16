import Carbon.HIToolbox
import CoreGraphics
import EdithKit

enum PushToTalkKey {
    static var code: Int {
        SharedDefaults.store.object(forKey: "pushToTalkHotKeyCode") as? Int ?? kVK_ANSI_M
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: "pushToTalkHotKeyMods") as? Int
            ?? (controlKey | optionKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: "pushToTalkHotKeyLabel") ?? "⌃⌥M"
    }
}

@MainActor
final class PushToTalkEngine: FeatureModule {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holding = false

    init() {
        _ = installEventTap()
    }

    func shutdown() {
        uninstallEventTap()
        releaseIfHolding()
    }

    private func installEventTap() -> Bool {
        func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << type.rawValue }
        let mask: CGEventMask = bit(.keyDown) | bit(.keyUp)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let engine = Unmanaged<PushToTalkEngine>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = engine.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passRetained(event)
            }
            engine.handle(type: type, event: event)
            return Unmanaged.passRetained(event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
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
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let matches = PushToTalkLogic.matches(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            targetKeyCode: Int64(PushToTalkKey.code),
            targetFlags: CarbonModifiers.toCGEventFlags(PushToTalkKey.mods))
        guard matches else { return }
        if type == .keyDown, !holding {
            holding = true
            AppState.services.micMute?.setMuted(false)
        } else if type == .keyUp {
            releaseIfHolding()
        }
    }

    private func releaseIfHolding() {
        guard holding else { return }
        holding = false
        AppState.services.micMute?.setMuted(true)
    }
}
