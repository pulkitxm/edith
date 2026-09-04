import AppKit
import EdithKit
import SwiftUI

private struct MachineViewPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var machineViewPresented: Bool {
        get { self[MachineViewPresentedKey.self] }
        set { self[MachineViewPresentedKey.self] = newValue }
    }
}

enum MachineActivityKind {
    case metrics
    case docker
    case internetSpeed
}

@MainActor
final class MachineActivityLease {
    private let token = UUID()
    private let kind: MachineActivityKind
    private var sessions: [UUID: MachineSession] = [:]

    init(kind: MachineActivityKind) { self.kind = kind }

    func update(_ candidates: [MachineSession], active: Bool) {
        let wanted =
            active
            ? Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        for (id, session) in sessions where wanted[id] !== session {
            change(session, active: false)
        }
        for (id, session) in wanted where sessions[id] !== session { change(session, active: true) }
        sessions = wanted
    }

    func release() { update([], active: false) }

    private func change(_ session: MachineSession, active: Bool) {
        switch kind {
        case .metrics:
            session.setForegroundObservation(token, active: active)
        case .docker:
            if active { session.beginDockerObservation() } else { session.endDockerObservation() }
        case .internetSpeed:
            if active {
                session.beginInternetSpeedObservation()
            } else {
                session.endInternetSpeedObservation()
            }
        }
    }
}

extension View {
    func machineActivity(_ session: MachineSession, kind: MachineActivityKind = .metrics)
        -> some View
    {
        machineActivity([session], kind: kind)
    }

    func machineActivity(_ sessions: [MachineSession], kind: MachineActivityKind = .metrics)
        -> some View
    {
        modifier(MachineActivityModifier(sessions: sessions, kind: kind))
    }
}

private struct MachineActivityModifier: ViewModifier {
    let sessions: [MachineSession]
    @Environment(\.machineViewPresented) private var presented
    @Environment(\.machineConnectionsEnabled) private var connectionsEnabled
    @State private var windowVisible = true
    @State private var lease: MachineActivityLease

    init(sessions: [MachineSession], kind: MachineActivityKind) {
        self.sessions = sessions
        _lease = State(initialValue: MachineActivityLease(kind: kind))
    }

    private var active: Bool { presented && windowVisible && connectionsEnabled }

    func body(content: Content) -> some View {
        content
            .environment(\.machineViewPresented, active)
            .background {
                MachineWindowVisibilityReader(visible: $windowVisible)
                    .frame(width: 0, height: 0)
            }
            .onChange(of: active, initial: true) { _, active in
                lease.update(sessions, active: active)
            }
            .onChange(of: sessions.map { ObjectIdentifier($0) }) { _, _ in
                lease.update(sessions, active: active)
            }
            .onDisappear { lease.release() }
    }
}

private struct MachineWindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> MachineWindowVisibilityView {
        let view = MachineWindowVisibilityView()
        view.changed = { value in
            DispatchQueue.main.async { visible = value }
        }
        return view
    }

    func updateNSView(_ nsView: MachineWindowVisibilityView, context: Context) {}

    static func dismantleNSView(_ nsView: MachineWindowVisibilityView, coordinator: ()) {
        nsView.stop()
    }
}

final class MachineWindowVisibilityView: NSView {
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
