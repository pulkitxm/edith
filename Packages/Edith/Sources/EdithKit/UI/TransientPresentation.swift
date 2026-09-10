import AppKit
import SwiftUI

private struct TransientPresentation: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .background(SheetDismissalMonitor(dismiss: { dismiss() }))
            .onExitCommand { dismiss() }
    }
}

struct SheetDismissalMonitor: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> SheetDismissalView {
        let view = SheetDismissalView()
        view.dismiss = dismiss
        return view
    }

    func updateNSView(_ view: SheetDismissalView, context: Context) {
        view.dismiss = dismiss
    }

    static func dismantleNSView(_ view: SheetDismissalView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class SheetDismissalView: NSView {
    var dismiss: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let dismissed = MainActor.assumeIsolated {
                guard let self, self.shouldDismiss(for: event) else { return false }
                self.dismiss?()
                return true
            }
            return dismissed ? nil : event
        }
    }

    func shouldDismiss(for event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, let sheet = window,
            let parent = sheet.sheetParent, parent.attachedSheet === sheet,
            sheet.attachedSheet == nil, event.window === parent
        else { return false }
        let location = parent.convertPoint(toScreen: event.locationInWindow)
        return parent.frame.contains(location) && !sheet.frame.contains(location)
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    public func transientPresentation() -> some View {
        modifier(TransientPresentation())
    }
}
