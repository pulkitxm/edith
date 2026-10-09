import AppKit

@MainActor
func nativeAccessibilityString(_ object: NSObject, selector: String) -> String? {
    let getter = NSSelectorFromString(selector)
    guard object.responds(to: getter) else { return nil }
    let value = object.perform(getter)?.takeUnretainedValue()
    return (value as? String) ?? (value as? NSAttributedString)?.string
}

@MainActor
func nativeAccessibilityMatches(_ object: NSObject, label: String) -> Bool {
    ["accessibilityLabel", "accessibilityTitle"].contains {
        nativeAccessibilityString(object, selector: $0) == label
    }
}
