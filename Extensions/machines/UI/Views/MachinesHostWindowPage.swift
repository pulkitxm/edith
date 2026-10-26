import EdithExtensionUI
import SwiftUI

struct MachinesHostWindowPage: View {
    let request: MachineHostWindowRequest
    @State private var model: MachinesModel

    init(request: MachineHostWindowRequest, model: MachinesModel? = nil) {
        self.request = request
        _model = State(initialValue: model ?? .shared)
    }
    @State private var terminals = TerminalTabsModel()

    var body: some View {
        Group {
            if model.knows(request.machineID) {
                let session = model.session(for: request.machineID)
                switch request.kind {
                case .machine: MachineWindowView(machineID: request.machineID, model: model)
                case .files: FinderWindowView(session: session, path: request.path)
                case .docker: DockerConsoleView(session: session)
                case .terminal: TerminalTabsView(session: session, model: terminals)
                }
            } else {
                PageSkeleton(layout: .editor)
            }
        }
        .navigationRoute("section", selection: .constant("machines"))
        .onDisappear { terminals.stopAll() }
    }
}
