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
            ZStack {
                sessionPane
                    .opacity(tab.view == .agent ? 1 : 0)
                    .allowsHitTesting(tab.view == .agent)
                diffPane
                    .opacity(tab.view == .diff ? 1 : 0)
                    .allowsHitTesting(tab.view == .diff)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.detailOpen {
                Divider().opacity(0.35)
                sidebar
                    .frame(width: UIScale.pt(compact ? 220 : 260))
            }
        }
        .task(id: tab.id) { await startIfNeeded() }
        .task(id: diffRequest) { await prepareDiffIfNeeded() }
    }

    private var diffRequest: String {
        "\(tab.id)|\(tab.view.rawValue)|\(dark)"
    }

    private var sessionPane: some View {
        ZStack {
            TerminalPane(holder: tab.holder, palette: .edith(dark: dark))
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

    private var diffPane: some View {
        let palette = TerminalPalette.quinjet(
            theme: diffConfiguration.theme, appearance: diffConfiguration.appearance)
        return ZStack {
            Color(nsColor: palette.background)
            TerminalPane(holder: tab.quinjet.holder, palette: palette)
                .id(tab.quinjet.holder.generation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(tab.quinjet.live ? 1 : 0)
            if let error = tab.quinjet.errorMessage {
                diffPlaceholder(
                    title: "Quinjet could not open this diff", detail: error, palette: palette)
            } else if tab.quinjet.preparing {
                ProgressView()
            } else if !launchEnabled {
                diffPlaceholder(
                    title: "Terminals are paused",
                    detail: "Enable terminal launching to load the Quinjet diff.",
                    palette: palette)
            } else if let message = tab.quinjet.holder.exitMessage {
                diffPlaceholder(title: message, detail: nil, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presenterCover(hideAgents, dark: dark)
    }

    private func diffPlaceholder(title: String, detail: String?, palette: TerminalPalette)
        -> some View
    {
        VStack(spacing: UIScale.pt(10)) {
            Text(title)
                .font(.system(size: UIScale.pt(14), weight: .semibold))
                .foregroundStyle(Color(nsColor: palette.foreground))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(Color(nsColor: palette.foreground).opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            Button("Retry") {
                Task { await prepareDiff(restarting: true) }
            }
            .buttonStyle(QuinjetToolbarButtonStyle())
            .pointerCursor()
        }
        .padding(UIScale.pt(28))
        .frame(maxWidth: UIScale.pt(420))
    }

    private var diffConfiguration: QuinjetLaunchConfiguration {
        store.quinjetConfiguration(appearance: dark ? .dark : .light)
    }

    private func prepareDiffIfNeeded() async {
        guard tab.view == .diff else { return }
        await prepareDiff(restarting: false)
    }

    private func prepareDiff(restarting: Bool) async {
        let configuration = diffConfiguration
        let remote: QuinjetRemote?
        do {
            remote = try await store.quinjetRemote(for: tab)
        } catch {
            tab.quinjet.errorMessage = error.localizedDescription
            return
        }
        if restarting {
            await tab.quinjet.restart(
                directory: agent.cwd, remote: remote, configuration: configuration,
                launchEnabled: launchEnabled)
        } else {
            await tab.quinjet.prepare(
                directory: agent.cwd, remote: remote, configuration: configuration,
                launchEnabled: launchEnabled)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                Text(hideAgents ? "Hidden" : agent.title)
                    .font(DashSkin.serif(20))
                    .foregroundStyle(hideAgents ? DashSkin.inkFaint(dark) : DashSkin.ink(dark))
                    .padding(.trailing, UIScale.pt(36))
                viewSection
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

    private var viewSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Text("View")
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            HerdrAgentViewToggle(selection: tab.view) { option in
                store.setView(option, for: tab.id)
            }
            if tab.view == .diff, let branch = tab.quinjet.branch {
                Text(branch)
                    .font(DashSkin.mono(10))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
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
