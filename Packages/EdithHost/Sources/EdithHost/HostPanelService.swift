import Carbon.HIToolbox
import EdithExtensionSupport
import Foundation

@MainActor final class HostPanelService {
    private let defaults: UserDefaults
    private let action: @MainActor () -> Void
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(defaults: UserDefaults, action: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.action = action
    }

    func install() throws {
        shutdown()
        let binding = try Self.binding(defaults: defaults)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                var key = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                        nil, &key) == noErr,
                    key.signature == OSType(0x4544_4350), key.id == 1
                else { return noErr }
                MainActor.assumeIsolated {
                    Unmanaged<HostPanelService>.fromOpaque(context).takeUnretainedValue().action()
                }
                return noErr
            }, 1, &eventType, context, &handler)
        guard result == noErr else { throw CocoaError(.featureUnsupported) }
        let registration = RegisterEventHotKey(
            binding.code, binding.modifiers,
            EventHotKeyID(signature: OSType(0x4544_4350), id: 1), GetApplicationEventTarget(), 0,
            &reference)
        guard registration == noErr, reference != nil else {
            shutdown(); throw CocoaError(.featureUnsupported)
        }
    }

    static func binding(defaults: UserDefaults) throws -> (code: UInt32, modifiers: UInt32) {
        let code = defaults.object(forKey: AppStorageKeys.General.hotKeyCode) as? Int ?? kVK_ANSI_E
        let modifiers =
            defaults.object(forKey: AppStorageKeys.General.hotKeyMods) as? Int ?? optionKey | cmdKey
        guard (0...127).contains(code), modifiers >= 0,
            modifiers & ~(optionKey | cmdKey | controlKey | shiftKey) == 0
        else { throw CocoaError(.coderInvalidValue) }
        return (UInt32(code), UInt32(modifiers))
    }

    func shutdown() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
