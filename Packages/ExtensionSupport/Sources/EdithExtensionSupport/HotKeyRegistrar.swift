import Carbon.HIToolbox
import Foundation

public struct ExtensionHotKeyBinding {
    public let id: String
    public let carbonID: UInt32
    public let prefix: String
    public let defaultCode: Int
    public let defaultModifiers: Int

    public init(
        id: String, carbonID: UInt32, prefix: String, defaultCode: Int, defaultModifiers: Int
    ) {
        self.id = id
        self.carbonID = carbonID
        self.prefix = prefix
        self.defaultCode = defaultCode
        self.defaultModifiers = defaultModifiers
    }
}

@MainActor
public enum HotKeyRegistrar {
    private static var bindings: [String: ExtensionHotKeyBinding] = [:]
    private static var actions: [String: () -> Void] = [:]
    private static var references: [String: EventHotKeyRef] = [:]
    private static var handler: EventHandlerRef?

    public static func configure(_ binding: ExtensionHotKeyBinding) {
        bindings[binding.id] = binding
    }

    public static func install(_ id: String, action: @escaping () -> Void) {
        clear(id)
        guard let binding = bindings[id] else { return }
        installHandler()
        let defaults = SharedDefaults.store
        let code = defaults.object(forKey: binding.prefix + "Code") as? Int ?? binding.defaultCode
        let modifiers =
            defaults.object(forKey: binding.prefix + "Mods") as? Int ?? binding.defaultModifiers
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(
            UInt32(clamping: code), UInt32(clamping: modifiers),
            EventHotKeyID(signature: OSType(0x4544_4954), id: binding.carbonID),
            GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else { return }
        references[id] = reference
        actions[id] = action
    }

    public static func clear(_ id: String) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        actions[id] = nil
    }

    public static func shutdown() {
        for id in Array(references.keys) { clear(id) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        bindings.removeAll()
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                        nil, &hotKeyID) == noErr,
                    hotKeyID.signature == OSType(0x4544_4954)
                else { return OSStatus(eventNotHandledErr) }
                let handled = MainActor.assumeIsolated {
                    HotKeyRegistrar.dispatch(hotKeyID.id)
                }
                return handled ? noErr : OSStatus(eventNotHandledErr)
            }, 1, &eventType, nil, &handler)
    }

    private static func dispatch(_ carbonID: UInt32) -> Bool {
        guard let binding = bindings.values.first(where: { $0.carbonID == carbonID }),
            let action = actions[binding.id]
        else { return false }
        action()
        return true
    }
}

public enum HotKeyCatalog {
    public static let emoji = "emoji"
    public static let focusDim = "focusDim"
    public static let hinge = "hinge"
    public static let colorPicker = "colorPicker"
    public static let micMute = "micMute"
    public static let presenter = "presenter"
    public static let keystrokeHighlight = "keystrokeHighlight"
    public static let virtualCamera = "virtualCamera"
}
