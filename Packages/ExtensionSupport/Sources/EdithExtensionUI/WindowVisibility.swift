import AppKit
import SwiftUI

private struct WindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    public var windowVisible: Bool {
        get { self[WindowVisibleKey.self] }
        set { self[WindowVisibleKey.self] = newValue }
    }
}

private struct WindowVisibilityModifier: ViewModifier {
    @State private var visible = true
    @Environment(\.extensionPresentationState) private var remotePresentation

    func body(content: Content) -> some View {
        content
            .environment(\.windowVisible, remotePresentation?.visible ?? visible)
            .background {
                if remotePresentation == nil {
                    WindowVisibilityReader(visible: $visible)
                        .frame(width: 0, height: 0)
                }
            }
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.changed = { value in
            DispatchQueue.main.async {
                guard visible != value else { return }
                visible = value
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowVisibilityView, coordinator: ()) {
        nsView.stop()
    }
}

extension View {
    public func tracksWindowVisibility() -> some View {
        modifier(WindowVisibilityModifier())
    }
}

final class WindowVisibilityView: NSView {
    var changed: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else {
            changed?(false)
            return
        }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
        refresh()
    }

    func refresh() {
        changed?(
            window.map { $0.isVisible && $0.occlusionState.contains(.visible) && !NSApp.isHidden }
                ?? false)
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

private struct CompactLayoutKey: EnvironmentKey { static let defaultValue = false }
private struct AutomaticViewActionsKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    public var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
    public var automaticViewActionsEnabled: Bool {
        get { self[AutomaticViewActionsKey.self] }
        set { self[AutomaticViewActionsKey.self] = newValue }
    }
}
