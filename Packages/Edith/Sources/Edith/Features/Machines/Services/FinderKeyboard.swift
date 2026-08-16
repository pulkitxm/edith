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

final class FinderKeyView: NSView {
    var onKey: ((FinderKey) -> Bool)?
    var isEditing: () -> Bool = { false }

    override var acceptsFirstResponder: Bool { true }

    static func isTextEditing(in window: NSWindow?) -> Bool {
        window?.firstResponder is NSText
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, window?.firstResponder !== self,
                !FinderKeyView.isTextEditing(in: window)
            else { return }
            window?.makeFirstResponder(self)
        }
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct FinderKeyCatcher: NSViewRepresentable {
    let isEditing: Bool
    let onKey: (FinderKey) -> Bool

    func makeNSView(context: Context) -> FinderKeyView {
        let view = FinderKeyView()
        view.onKey = onKey
        view.isEditing = { context.coordinator.editing }
        return view
    }

    func updateNSView(_ view: FinderKeyView, context: Context) {
        context.coordinator.editing = isEditing
        view.onKey = onKey
        if !isEditing, view.window?.firstResponder !== view,
            !FinderKeyView.isTextEditing(in: view.window)
        {
            DispatchQueue.main.async {
                guard !FinderKeyView.isTextEditing(in: view.window) else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(editing: isEditing) }

    final class Coordinator {
        var editing: Bool

        init(editing: Bool) {
            self.editing = editing
        }
    }
}
