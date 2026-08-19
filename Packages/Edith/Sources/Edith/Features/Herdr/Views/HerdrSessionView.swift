import EdithKit
import SwiftTerm
import SwiftUI

struct HerdrSessionView: View {
    var store: HerdrStore
    let tab: HerdrOpenTab
    let launchEnabled: Bool
    var hideAgents = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var connectError: String?
    @State private var starting = false

    private var dark: Bool { scheme == .dark }
    private var agent: HerdrAgent { tab.agent }
    private var command: String { HerdrAttachCommand.line(for: agent) }

    var body: some View {
        HStack(spacing: 0) {
            sessionPane
            if store.detailOpen {
                Divider().opacity(0.35)
                sidebar
                    .frame(width: UIScale.pt(compact ? 220 : 260))
            }
        }
        .task(id: tab.id) { await startIfNeeded() }
    }

    private var sessionPane: some View {
        ZStack {
            TerminalPane(holder: tab.holder, dark: dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let connectError {
                Text(connectError)
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(DashSkin.warn)
                    .padding(UIScale.pt(16))
            } else if starting, !tab.holder.started {
                ProgressView()
            }
        }
        .background(dark ? Color.black.opacity(0.9) : Color.white)
        .presenterCover(hideAgents, dark: dark)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                Text(hideAgents ? "Hidden" : agent.title)
                    .font(DashSkin.serif(20))
                    .foregroundStyle(hideAgents ? DashSkin.inkFaint(dark) : DashSkin.ink(dark))
                    .padding(.trailing, UIScale.pt(36))
                kindRow
                metaRow("Status", agent.status.title)
                metaRow("Machine", agent.machineName)
                if !hideAgents {
                    metaRow("Session", agent.session)
                    metaRow("Pane", agent.pane)
                    if !agent.workspace.isEmpty { metaRow("Workspace", agent.workspace) }
                    if !agent.cwd.isEmpty { metaRow("Directory", agent.cwd) }
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        Text("Attach")
                            .font(.system(size: UIScale.pt(11), weight: .semibold))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Text(command)
                            .font(DashSkin.mono(10))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .textSelection(.enabled)
                        Button {
                            store.copyAttachCommand(for: agent)
                        } label: {
                            Label(
                                store.copiedID == agent.id
                                    ? "Copied"
                                    : (agent.machineIsLocal ? "Copy command" : "Copy SSH"),
                                systemImage: store.copiedID == agent.id
                                    ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(HoverButtonStyle())
                    }
                }
            }
            .padding(UIScale.pt(16))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DashSkin.paper(dark))
    }

    private var kindRow: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text("Kind")
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            HStack(spacing: UIScale.pt(8)) {
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(14))
                Text(agent.kind)
                    .font(.system(size: UIScale.pt(12.5)))
                    .textSelection(.enabled)
            }
            .foregroundStyle(DashSkin.ink(dark))
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(label)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .textSelection(.enabled)
        }
    }

    private func startIfNeeded() async {
        guard launchEnabled, !tab.holder.started else { return }
        starting = true
        defer { starting = false }
        if agent.machineIsLocal {
            startLocal()
            return
        }
        guard let machine = tab.machine else {
            connectError = "That machine is no longer in Edith."
            return
        }
        do {
            let connection = try await store.connection(for: machine)
            tab.holder.start(
                executable: SSHConnection.executable.path,
                arguments: connection.terminalArguments(
                    remoteCommand: HerdrAttachCommand.remoteShellLine(
                        session: agent.session, pane: agent.pane)),
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
                    + connection.terminalEnvironment())
        } catch {
            connectError = error.localizedDescription
        }
    }

    private func startLocal() {
        let environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if let executable = HerdrCollector.executable() {
            tab.holder.start(
                executable: executable.path,
                arguments: HerdrAttachCommand.arguments(session: agent.session, pane: agent.pane),
                environment: environment)
            return
        }
        tab.holder.start(
            executable: "/bin/zsh",
            arguments: [
                "-c", HerdrAttachCommand.remoteShellLine(session: agent.session, pane: agent.pane),
            ],
            environment: environment)
    }
}
