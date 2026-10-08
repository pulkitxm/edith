import AppKit
import SwiftUI

private struct TransientPresentation: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let dismissible: Bool
    let dismissOnEscape: Bool
    var onEscape: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .background(
                SheetDismissalMonitor(
                    dismissible: dismissible, dismissOnEscape: dismissOnEscape,
                    onEscape: onEscape, dismiss: { dismiss() })
            )
            .interactiveDismissDisabled(!dismissible)
    }
}

struct SheetDismissalMonitor: NSViewRepresentable {
    let dismissible: Bool
    let dismissOnEscape: Bool
    var onEscape: (() -> Void)? = nil
    let dismiss: () -> Void

    func makeNSView(context: Context) -> SheetDismissalView {
        let view = SheetDismissalView()
        view.dismissible = dismissible
        view.dismissOnEscape = dismissOnEscape
        view.onEscape = onEscape
        view.dismiss = dismiss
        return view
    }

    func updateNSView(_ view: SheetDismissalView, context: Context) {
        view.dismissible = dismissible
        view.dismissOnEscape = dismissOnEscape
        view.onEscape = onEscape
        view.dismiss = dismiss
    }

    static func dismantleNSView(_ view: SheetDismissalView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class SheetDismissalView: NSView {
    var dismissible = true
    var dismissOnEscape = true
    var onEscape: (() -> Void)?
    var dismiss: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) {
            [weak self] event in
            let dismissed = MainActor.assumeIsolated {
                guard let self, self.shouldDismiss(for: event) else { return false }
                if event.type == .keyDown, let onEscape = self.onEscape {
                    onEscape()
                } else {
                    self.dismiss?()
                }
                return true
            }
            return dismissed ? nil : event
        }
    }

    func shouldDismiss(for event: NSEvent) -> Bool {
        guard dismissible, let sheet = window,
            let parent = sheet.sheetParent, parent.attachedSheet === sheet,
            sheet.attachedSheet == nil, NSApp.modalWindow == nil,
            !(NSApp.keyWindow is NSSavePanel)
        else { return false }
        if event.type == .keyDown {
            return (dismissOnEscape || onEscape != nil) && event.keyCode == 53
                && event.window === sheet
                && NSApp.keyWindow === sheet
                && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        }
        guard event.type == .leftMouseDown, event.window === parent else { return false }
        let location = parent.convertPoint(toScreen: event.locationInWindow)
        return parent.frame.contains(location) && !sheet.frame.contains(location)
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    public func transientPresentation(
        dismissible: Bool = true, dismissOnEscape: Bool = true,
        onEscape: (() -> Void)? = nil
    ) -> some View {
        modifier(
            TransientPresentation(
                dismissible: dismissible, dismissOnEscape: dismissOnEscape, onEscape: onEscape))
    }

    public func edithSheet<Content: View>(
        isPresented: Binding<Bool>, dismissible: Bool? = true, dismissOnEscape: Bool = true,
        onEscape: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            if let dismissible {
                content().transientPresentation(
                    dismissible: dismissible, dismissOnEscape: dismissOnEscape, onEscape: onEscape)
            } else {
                content()
            }
        }
    }

    public func edithSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, dismissible: Bool? = true, dismissOnEscape: Bool = true,
        onEscape: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in
            if let dismissible {
                content(item).transientPresentation(
                    dismissible: dismissible, dismissOnEscape: dismissOnEscape, onEscape: onEscape)
            } else {
                content(item)
            }
        }
    }
}
