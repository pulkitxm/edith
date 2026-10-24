import AppKit
import EdithKit
import SwiftUI

enum FinderKey: Equatable {
    case rename
    case openSelection
    case quickLook
    case move(FinderMoveDirection, extend: Bool)
    case enclosingFolder
    case back
    case forward
    case selectAll
    case trash
    case deleteImmediately
    case newFolder
    case copy
    case cut
    case paste
    case copyPath
    case info
    case refresh
    case toggleHidden
    case duplicate
    case undo
    case redo
    case invertSelection
    case toggleSidebar
    case iconView
    case listView
    case focusSearch
    case cancel
    case type(String)

    static func resolve(event: NSEvent) -> FinderKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        switch event.keyCode {
        case 36, 76:
            return command ? .openSelection : .rename
        case 49:
            return .quickLook
        case 126:
            return command ? .enclosingFolder : .move(.up, extend: shift)
        case 125:
            return command ? .openSelection : .move(.down, extend: shift)
        case 123:
            return command ? .back : .move(.left, extend: shift)
        case 124:
            return command ? .forward : .move(.right, extend: shift)
        case 51, 117:
            guard command else { return nil }
            return option ? .deleteImmediately : .trash
        case 53:
            return .cancel
        default:
            break
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        if command {
            switch characters {
            case "[": return .back
            case "]": return .forward
            case "a": return shift ? .invertSelection : .selectAll
            case "d": return .duplicate
            case "z": return shift ? .redo : .undo
            case "n" where shift: return .newFolder
            case "c": return option ? .copyPath : .copy
            case "x": return .cut
            case "v": return .paste
            case "i": return .info
            case "r": return .refresh
            case ".": return shift ? .toggleHidden : nil
            case "s" where flags.contains(.control): return .toggleSidebar
            case "1": return .iconView
            case "2": return .listView
            case "f": return .focusSearch
            case "y": return .quickLook
            default: return nil
            }
        }
        guard !option, !flags.contains(.control), let scalar = characters.unicodeScalars.first,
            CharacterSet.alphanumerics.contains(scalar) || characters == "."
        else { return nil }
        return .type(characters)
    }
}

final class FinderKeyView: NSView, DirectKeyboardInputResponder, HistoryNavigatingView {
    var onKey: ((FinderKey) -> Bool)?
    var onHistory: ((NavigationDirection) -> Bool)?
    var onFocus: (() -> Void)?
    var isEditing: () -> Bool = { false }
    var autoFocus = true

    override var acceptsFirstResponder: Bool { true }

    static func isTextEditing(in window: NSWindow?) -> Bool {
        window?.firstResponder is NSText
    }

    static func windowIsIdle(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.firstResponder == nil || window.firstResponder === window
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, autoFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, window?.firstResponder !== self,
                !FinderKeyView.isTextEditing(in: window)
            else { return }
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard !isEditing(), !FinderKeyView.isTextEditing(in: window),
            let key = FinderKey.resolve(event: event),
            onKey?(key) == true
        else {
            super.keyDown(with: event)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !isEditing(),
            event.modifierFlags.contains(.command),
            let key = FinderKey.resolve(event: event),
            onKey?(key) == true
        else { return super.performKeyEquivalent(with: event) }
        return true
    }

    func navigateHistory(_ direction: NavigationDirection) -> Bool {
        guard !isEditing() else { return false }
        return onHistory?(direction) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct FinderKeyCatcher: NSViewRepresentable {
    let isEditing: Bool
    var focusRequests = 0
    var autoFocus = true
    var onFocus: (() -> Void)?
    var onHistory: ((NavigationDirection) -> Bool)?
    let onKey: (FinderKey) -> Bool

    func makeNSView(context: Context) -> FinderKeyView {
        let view = FinderKeyView()
        view.autoFocus = autoFocus
        view.onKey = onKey
        view.onFocus = onFocus
        view.onHistory = onHistory
        view.isEditing = { context.coordinator.editing }
        return view
    }

    func updateNSView(_ view: FinderKeyView, context: Context) {
        context.coordinator.editing = isEditing
        view.autoFocus = autoFocus
        view.onKey = onKey
        view.onFocus = onFocus
        view.onHistory = onHistory
        let requested = context.coordinator.focusRequests != focusRequests
        context.coordinator.focusRequests = focusRequests
        guard
            Self.claimsFocus(
                requested: requested, autoFocus: autoFocus, editing: isEditing,
                focused: view.window?.firstResponder === view,
                textEditing: FinderKeyView.isTextEditing(in: view.window),
                windowIdle: FinderKeyView.windowIsIdle(view.window))
        else { return }
        DispatchQueue.main.async {
            guard !FinderKeyView.isTextEditing(in: view.window) else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    static func claimsFocus(
        requested: Bool, autoFocus: Bool, editing: Bool, focused: Bool, textEditing: Bool,
        windowIdle: Bool
    ) -> Bool {
        guard !editing, !focused, !textEditing else { return false }
        return requested || (autoFocus && windowIdle)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(editing: isEditing, focusRequests: focusRequests)
    }

    final class Coordinator {
        var editing: Bool
        var focusRequests: Int

        init(editing: Bool, focusRequests: Int) {
            self.editing = editing
            self.focusRequests = focusRequests
        }
    }
}
