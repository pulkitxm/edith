import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

extension FinderModel {
    static func machine(session: MachineSession, path: String? = nil) -> FinderModel {
        let model = FinderModel(
            session: session, path: path,
            peerSession: { MachinesModel.shared.sessions[$0] })
        model.openInNewWindow = { [weak session] path in
            guard let session else { return }
            FinderWindow.open(session: session, path: path)
        }
        return model
    }
}

struct MachineFinderPane: View {
    let model: FinderModel
    var allowsConnections = true
    var autoFocus = true
    var onFocus: (() -> Void)?
    @Environment(\.machineConnectionsEnabled) private var connectionsEnabled

    private var connectionsAllowed: Bool { allowsConnections && connectionsEnabled }

    var body: some View {
        FinderPane(
            model: model, allowsConnections: allowsConnections, autoFocus: autoFocus,
            onFocus: onFocus
        )
        .onAppear {
            if connectionsAllowed { FinderUndoBridge.register(model) }
        }
        .onDisappear {
            if connectionsAllowed { FinderUndoBridge.forget(model) }
        }
    }
}

struct FinderWindowView: View {
    let session: MachineSession
    @State private var model: FinderModel

    init(session: MachineSession, path: String? = nil) {
        self.session = session
        _model = State(wrappedValue: FinderModel.machine(session: session, path: path))
    }

    var body: some View {
        FinderPane(model: model)
            .machineActivity(session)
    }
}

@MainActor
enum FinderWindow {
    static func open(session: MachineSession, path: String? = nil) {
        guard let client = session.uiClient else {
            MachinesModel.shared.operationError = "The owning app window bridge is unavailable."
            return
        }
        client.enqueue {
            try await client.openWindow(
                .init(
                    kind: .files, machineID: session.id, path: path, title: session.machine.name,
                    subtitle: path ?? (session.isLocal ? "Home" : "Files")))
        }
    }
}
