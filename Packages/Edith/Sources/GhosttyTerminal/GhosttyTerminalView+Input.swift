import AppKit
import GhosttyKit

extension GhosttyTerminalView {
    static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var value = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(value)
    }

    public override func keyDown(with event: NSEvent) {
        guard send(event: event, action: GHOSTTY_ACTION_PRESS) else {
            super.keyDown(with: event)
            return
        }
    }

    public override func keyUp(with event: NSEvent) {
        _ = send(event: event, action: GHOSTTY_ACTION_RELEASE)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = Self.modifierAction(for: event)
        key.mods = Self.mods(from: event.modifierFlags)
        key.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false
        _ = ghostty_surface_key(surface, key)
        if let point = currentMousePoint() {
            ghostty_surface_mouse_pos(
                surface, Double(point.x), Double(bounds.height - point.y),
                Self.mods(from: event.modifierFlags))
        }
    }

    static func modifierAction(for event: NSEvent) -> ghostty_input_action_e {
        let active: Bool
        switch event.keyCode {
        case 54, 55: active = event.modifierFlags.contains(.command)
        case 56, 60: active = event.modifierFlags.contains(.shift)
        case 58, 61: active = event.modifierFlags.contains(.option)
        case 59, 62: active = event.modifierFlags.contains(.control)
        case 57: active = event.modifierFlags.contains(.capsLock)
        default: active = false
        }
        return active ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            copyTerminalSelection(nil)
            return true
        case "v":
            pasteTerminalClipboard(nil)
            return true
        case "a":
            selectAllTerminalText(nil)
            return true
        case "k":
            clearTerminalScrollback(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func send(event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        let characters = Self.inputText(for: event)
        var key = ghostty_input_key_s()
        key.action =
            event.isARepeat && action == GHOSTTY_ACTION_PRESS
            ? GHOSTTY_ACTION_REPEAT : action
        key.mods = Self.mods(from: event.modifierFlags)
        key.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint =
            event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
        key.composing = false
        guard let characters else {
            key.text = nil
            return ghostty_surface_key(surface, key)
        }
        return characters.withCString { pointer in
            key.text = pointer
            return ghostty_surface_key(surface, key)
        }
    }

    static func inputText(for event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        if characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first,
            scalar.value >= 0xF700, scalar.value <= 0xF8FF
        {
            return nil
        }
        return characters
    }

    private func point(for event: NSEvent) -> (Double, Double) {
        let local = convert(event.locationInWindow, from: nil)
        lastMousePoint = local
        return (Double(local.x), Double(bounds.height - local.y))
    }

    private func currentMousePoint() -> NSPoint? {
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.insetBy(dx: -1, dy: -1).contains(point) {
                lastMousePoint = point
                return point
            }
        }
        return lastMousePoint
    }

    private func button(
        _ event: NSEvent, _ state: ghostty_input_mouse_state_e,
        _ which: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        let position = point(for: event)
        ghostty_surface_mouse_pos(
            surface, position.0, position.1, Self.mods(from: event.modifierFlags))
        _ = ghostty_surface_mouse_button(
            surface, state, which, Self.mods(from: event.modifierFlags))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 1 {
            button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
        } else if let surface {
            _ = ghostty_surface_mouse_button(
                surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT,
                Self.mods(from: event.modifierFlags))
        }
    }

    public override func mouseUp(with event: NSEvent) {
        let selectionWasActive = hasSelection
        commandClickReleaseActive = event.modifierFlags.contains(.command)
        commandClickOpenedTarget = false
        button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT)
        if commandClickReleaseActive, !commandClickOpenedTarget, !selectionWasActive,
            let target = terminalTargetAtPointer()
        {
            _ = openTerminalTarget(target)
        }
        commandClickReleaseActive = false
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let surface, ghostty_surface_mouse_captured(surface) else {
            super.rightMouseDown(with: event)
            return
        }
        button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard let surface, ghostty_surface_mouse_captured(surface) else {
            super.rightMouseUp(with: event)
            return
        }
        button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE)
    }

    public override func mouseDragged(with event: NSEvent) {
        moved(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        moved(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        moved(event)
    }

    public override func mouseMoved(with event: NSEvent) {
        moved(event)
    }

    public override func mouseEntered(with event: NSEvent) {
        moved(event)
    }

    public override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(from: event.modifierFlags))
        setHoveredLink(nil)
    }

    private func moved(_ event: NSEvent) {
        guard let surface else { return }
        let position = point(for: event)
        ghostty_surface_mouse_pos(
            surface, position.0, position.1, Self.mods(from: event.modifierFlags))
    }

    static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    static func scrollMods(precise: Bool, phase: NSEvent.Phase) -> Int32 {
        var value: Int32 = precise ? 1 : 0
        value |= Int32(momentum(phase)) << 1
        return value
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let precise = event.hasPreciseScrollingDeltas
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if precise {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(
            surface, Double(x), Double(y),
            Self.scrollMods(precise: precise, phase: event.momentumPhase))
    }

    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                owner: self))
    }

    func terminalTargetAtPointer() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: raw, count: Int(text.text_len)), as: UTF8.self)
    }

    @objc func copyTerminalSelection(_ sender: Any?) {
        guard surface != nil else { return }
        if performBindingAction("copy_to_clipboard") { return }
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func pasteTerminalClipboard(_ sender: Any?) {
        guard surface != nil else { return }
        if performBindingAction("paste_from_clipboard") { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        _ = insertText(text)
    }

    @objc func selectAllTerminalText(_ sender: Any?) {
        _ = performBindingAction("select_all")
    }

    @objc func clearTerminalScrollback(_ sender: Any?) {
        _ = performBindingAction("clear_screen")
    }

    @discardableResult
    func performBindingAction(_ name: String) -> Bool {
        guard let surface else { return false }
        return name.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(name.utf8.count))
        }
    }

    @objc func openContextLink(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        _ = openTerminalTarget(rawValue)
    }

    @objc func copyContextLink(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawValue, forType: .string)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface, !ghostty_surface_mouse_captured(surface) else { return nil }
        window?.makeFirstResponder(self)
        let position = point(for: event)
        ghostty_surface_mouse_pos(
            surface, position.0, position.1, Self.mods(from: event.modifierFlags))
        let link = hoveredLink ?? terminalTargetAtPointer()
        let menu = NSMenu()
        if let link, Self.linkTarget(for: link, workingDirectory: currentDirectory) != nil {
            let open = menu.addItem(
                withTitle: "Open Link", action: #selector(openContextLink(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = link
            let copyLink = menu.addItem(
                withTitle: "Copy Link", action: #selector(copyContextLink(_:)), keyEquivalent: "")
            copyLink.target = self
            copyLink.representedObject = link
            menu.addItem(.separator())
        }
        if hasSelection {
            let copy = menu.addItem(
                withTitle: "Copy", action: #selector(copyTerminalSelection(_:)), keyEquivalent: "")
            copy.target = self
        }
        let paste = menu.addItem(
            withTitle: "Paste", action: #selector(pasteTerminalClipboard(_:)), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = NSPasteboard.general.string(forType: .string) != nil
        let selectAll = menu.addItem(
            withTitle: "Select All", action: #selector(selectAllTerminalText(_:)), keyEquivalent: ""
        )
        selectAll.target = self
        menu.addItem(.separator())
        let clear = menu.addItem(
            withTitle: "Clear Scrollback", action: #selector(clearTerminalScrollback(_:)),
            keyEquivalent: "")
        clear.target = self
        return menu
    }
}
