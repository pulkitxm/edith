import AppKit
import ApplicationServices
import Foundation

enum CommandBarSelectionAccess {
    static let maximumLength = 20_000

    static func read(processIdentifier: pid_t?) -> CommandBarSelection? {
        guard AXIsProcessTrusted(), let processIdentifier,
            processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let focused = element(application, attribute: kAXFocusedUIElementAttribute),
            let text = string(focused, attribute: kAXSelectedTextAttribute)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.count <= maximumLength else { return nil }
        return CommandBarSelection(processIdentifier: processIdentifier, text: text)
    }

    static func replace(_ selection: CommandBarSelection, with text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(selection.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let focused = element(application, attribute: kAXFocusedUIElementAttribute) else {
            return false
        }
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                focused, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return false }
        return AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private static func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute: attribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        guard let value = value(element, attribute: attribute),
            CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return value as? String
    }

    private static func value(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}
