import AppKit
import SwiftUI

@MainActor
final class WorkspaceCommandMonitor {
    private var monitor: Any?
    private weak var window: NSWindow?
    var handler: (WindowWorkspaceCommand) -> Bool = { _ in false }

    func install(in window: NSWindow?) {
        remove()
        self.window = window
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
            let command = WindowWorkspaceCommand.resolve(
                characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                modifiers: event.modifierFlags)
        else { return false }
        return handler(command)
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
    }
}

private struct WorkspaceCommandHost: NSViewRepresentable {
    let handler: (WindowWorkspaceCommand) -> Bool

    func makeCoordinator() -> WorkspaceCommandMonitor { WorkspaceCommandMonitor() }

    func makeNSView(context: Context) -> WorkspaceCommandAnchor {
        let view = WorkspaceCommandAnchor()
        view.monitor = context.coordinator
        return view
    }

    func updateNSView(_ view: WorkspaceCommandAnchor, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(
        _ view: WorkspaceCommandAnchor, coordinator: WorkspaceCommandMonitor
    ) {
        coordinator.remove()
    }
}

private final class WorkspaceCommandAnchor: NSView {
    weak var monitor: WorkspaceCommandMonitor?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated { monitor?.install(in: window) }
    }
}

extension View {
    func workspaceCommands(_ handler: @escaping (WindowWorkspaceCommand) -> Bool) -> some View {
        background(WorkspaceCommandHost(handler: handler))
    }
}
