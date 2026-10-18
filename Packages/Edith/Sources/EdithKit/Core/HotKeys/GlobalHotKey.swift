import Carbon.HIToolbox
import Foundation

private func dispatchGlobalHotKey(_ id: UInt32) {
    if let action = GlobalHotKey.actions[id] {
        DispatchQueue.main.async {
            PerformanceTrace.measure(.input, "helper.globalHotKey") { action() }
        }
    }
}

enum GlobalHotKey {
    fileprivate static var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
                    &hotKeyID)
                dispatchGlobalHotKey(hotKeyID.id)
                return noErr
            }, 1, &eventType, nil, nil)
        handlerInstalled = true
    }

    static func set(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerOnce()
        clear(id: id)
        actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4544_4954), id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
    }

    static func clear(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: id)
    }
}
