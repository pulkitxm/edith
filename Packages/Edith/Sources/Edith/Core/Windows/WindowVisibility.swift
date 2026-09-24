import SwiftUI

private struct WindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var windowVisible: Bool {
        get { self[WindowVisibleKey.self] }
        set { self[WindowVisibleKey.self] = newValue }
    }
}

private struct WindowVisibilityModifier: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .environment(\.windowVisible, visible)
            .background {
                WindowVisibilityReader(visible: $visible)
                    .frame(width: 0, height: 0)
            }
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> MachineWindowVisibilityView {
        let view = MachineWindowVisibilityView()
        view.changed = { value in
            DispatchQueue.main.async {
                guard visible != value else { return }
                visible = value
            }
        }
        return view
    }

    func updateNSView(_ nsView: MachineWindowVisibilityView, context: Context) {}

    static func dismantleNSView(_ nsView: MachineWindowVisibilityView, coordinator: ()) {
        nsView.stop()
    }
}

extension View {
    func tracksWindowVisibility() -> some View {
        modifier(WindowVisibilityModifier())
    }
}
