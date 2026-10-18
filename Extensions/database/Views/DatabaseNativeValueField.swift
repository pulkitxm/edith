import AppKit

final class DatabaseNativeValueField: NSTextField {
    var editingValue = ""

    override func selectText(_ sender: Any?) {
        if isEditable { stringValue = editingValue }
        super.selectText(sender)
    }

    override func becomeFirstResponder() -> Bool {
        if isEditable { stringValue = editingValue }
        return super.becomeFirstResponder()
    }
}
