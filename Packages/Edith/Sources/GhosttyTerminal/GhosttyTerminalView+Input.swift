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
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = Self.mods(from: event.modifierFlags)
        key.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false
        _ = ghostty_surface_key(surface, key)
    }

    private func send(event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        let characters = event.characters ?? ""
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
        guard !characters.isEmpty else {
            key.text = nil
            return ghostty_surface_key(surface, key)
        }
        return characters.withCString { pointer in
            key.text = pointer
            return ghostty_surface_key(surface, key)
        }
    }

    private func point(for event: NSEvent) -> (Double, Double) {
        let local = convert(event.locationInWindow, from: nil)
        return (Double(local.x), Double(bounds.height - local.y))
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
        button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }

    public override func mouseUp(with event: NSEvent) {
        button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT)
    }

    public override func rightMouseDown(with event: NSEvent) {
        button(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT)
    }

    public override func rightMouseUp(with event: NSEvent) {
        button(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT)
    }

    public override func mouseDragged(with event: NSEvent) {
        moved(event)
    }

    public override func mouseMoved(with event: NSEvent) {
        moved(event)
    }

    private func moved(_ event: NSEvent) {
        guard let surface else { return }
        let position = point(for: event)
        ghostty_surface_mouse_pos(
            surface, position.0, position.1, Self.mods(from: event.modifierFlags))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var flags: Int32 = 0
        if event.hasPreciseScrollingDeltas { flags |= 1 }
        if event.momentumPhase != [] { flags |= 2 }
        ghostty_surface_mouse_scroll(
            surface, Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), flags)
    }
}
