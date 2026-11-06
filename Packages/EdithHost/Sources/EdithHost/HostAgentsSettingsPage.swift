import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostAgentsSettingsPage: View {
    @State private var model: HostAgentsSettingsModel
    @Environment(\.automaticViewActionsEnabled) private var automaticActions

    init(model: HostAgentsSettingsModel) { _model = State(initialValue: model) }

    init(defaults: UserDefaults) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let executable =
            HostToolingCLI.bundledLauncher()
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ed")
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(
            String.init)
        self.init(
            model: HostAgentsSettingsModel(
                installer: HostMCPInstaller(
                    home: home, command: executable.path,
                    codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"],
                    tools: .system(home: home, path: path)),
                defaults: defaults,
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }))
    }

    var body: some View {
        PageLoading(
            state: model.load.state, title: "Connect agents",
            errorTitle: "Could not read agent settings",
            layout: .form, retry: { Task { await model.refresh() } }
        ) {
            Form {
                clientsSection
                connectAllSection
                terminalSection
            }
            .edithForm()
        }
        .navigationTitle("Connect agents")
        .pageTask(cancel: model.cancel) { await model.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if automaticActions, model.running == nil { Task { await model.refresh() } }
        }
    }

    private var clientsSection: some View {
        Section {
            ForEach(model.reports, id: \.client) { report in
                HostAgentClientRow(model: model, report: report)
            }
        } header: {
            Text("Coding agents")
        } footer: {
            Text(
                "Connecting gives the agent an MCP server named edith that runs \(model.display(model.installer.command)) mcp, so it can use your Edith extensions."
            )
            .font(.system(size: UIScale.pt(10)))
        }
    }

    private var connectAllSection: some View {
        Section {
            SettingsRow(
                "Connect every agent",
                subtitle: model.pending.isEmpty
                    ? "Every agent found on this Mac is connected."
                    : "Connects the agents found on this Mac that are not connected yet."
            ) {
                HostAgentActionButton(
                    title: "Connect all", running: "Connecting...", style: .primary,
                    busy: model.running == .connectAll, enabled: model.canConnectAll
                ) { model.run(.connectAll) }
                .accessibilityIdentifier("agents.connectAll")
            }
        }
    }

    private var terminalSection: some View {
        Section {
            HostAgentSnippet(
                text: HostGetStarted.agentCommand,
                copied: model.copied == HostGetStarted.agentCommand
            ) { model.copySnippet(HostGetStarted.agentCommand) }
        } header: {
            Text("From a terminal")
        } footer: {
            Text("ed mcp status shows the same report, and ed mcp uninstall removes the entry.")
                .font(.system(size: UIScale.pt(10)))
        }
    }
}

private struct HostAgentClientRow: View {
    let model: HostAgentsSettingsModel
    let report: HostMCPInstaller.Report
    @Environment(\.colorScheme) private var scheme

    private var client: HostMCPClient { report.client }
    private var busy: Bool {
        switch model.running {
        case .connect(let target), .disconnect(let target): target == client
        case .connectAll: report.clientFound && report.connection != .connected
        case nil: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                    identity
                    Spacer(minLength: UIScale.pt(PageMetrics.controlSpacing))
                    status.fixedSize()
                    action.fixedSize()
                }
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    identity
                    HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                        status
                        Spacer(minLength: UIScale.pt(PageMetrics.controlSpacing))
                        action.fixedSize()
                    }
                    .padding(.leading, UIScale.pt(logoSize + 10))
                }
            }
            if let detail = model.results[client] ?? model.guidance(report) {
                HostAgentResultView(model: model, result: detail)
                    .padding(.leading, UIScale.pt(logoSize + 10))
            }
        }
        .padding(.vertical, UIScale.pt(2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents.\(client.rawValue)")
    }

    private let logoSize = 22.0

    private var identity: some View {
        HStack(alignment: .center, spacing: UIScale.pt(10)) {
            HostAgentMark(client: client)
                .frame(width: UIScale.pt(logoSize), height: UIScale.pt(logoSize))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(client.title)
                Text(subtitle).settingsSubtitle().lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        report.clientFound ? "Installed on this Mac" : "Not found on this Mac"
    }

    private var status: some View {
        HStack(spacing: UIScale.pt(6)) {
            Circle().fill(tint).frame(width: UIScale.pt(7), height: UIScale.pt(7))
            Text(report.connection.title).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(report.connection.title)")
    }

    private var tint: Color {
        switch report.connection {
        case .connected: DashSkin.ok
        case .otherEdith, .manual: DashSkin.warn
        case .notConnected: DashSkin.inkFaint(scheme == .dark)
        }
    }

    @ViewBuilder private var action: some View {
        let enabled = model.running == nil
        switch report.connection {
        case .connected:
            HostAgentActionButton(
                title: "Disconnect", running: "Disconnecting...", style: .secondary, busy: busy,
                enabled: enabled
            ) { model.run(.disconnect(client)) }
            .accessibilityLabel("Disconnect \(client.title)")
        case .notConnected, .otherEdith:
            HostAgentActionButton(
                title: "Connect", running: "Connecting...", style: .primary, busy: busy,
                enabled: enabled
            ) { model.run(.connect(client)) }
            .accessibilityLabel("Connect \(client.title)")
        case .manual:
            HostAgentActionButton(
                title: "Check again", running: "Checking...", style: .secondary,
                busy: model.load.isRunning, enabled: enabled && !model.load.isRunning
            ) { Task { await model.refresh() } }
            .accessibilityLabel("Check \(client.title) again")
        }
    }
}

private struct HostAgentResultView: View {
    let model: HostAgentsSettingsModel
    let result: HostAgentResult

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(5)) {
                EdithIconView(result.succeeded ? .success : .warning)
                    .foregroundStyle(result.succeeded ? DashSkin.ok : DashSkin.warn)
                Text(result.message).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.edithText(.callout))
            if let snippet = result.snippet {
                HostAgentSnippet(text: snippet, copied: model.copied == snippet) {
                    model.copySnippet(snippet)
                }
            }
        }
        .transition(.opacity)
    }
}

private struct HostAgentSnippet: View {
    let text: String
    let copied: Bool
    let copy: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            Text(text)
                .font(.system(size: UIScale.pt(11), design: .monospaced))
                .foregroundStyle(DashSkin.ink(scheme == .dark))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy", action: copy)
                .buttonStyle(.edith(.secondary))
                .fixedSize()
                .accessibilityLabel(copied ? "Copied" : "Copy \(text)")
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(8))
        .background(
            RoundedRectangle(cornerRadius: UIScale.pt(6), style: .continuous)
                .fill(DashSkin.paper(scheme == .dark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(6), style: .continuous)
                .strokeBorder(DashSkin.line(scheme == .dark))
        )
    }
}

private struct HostAgentActionButton: View {
    let title: String
    let running: String
    let style: EdithButtonRole
    let busy: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(5)) {
                if busy {
                    SkeletonGroup { SkeletonBlock(width: 12, height: 12, corner: 6) }
                }
                Text(busy ? running : title)
            }
        }
        .buttonStyle(.edith(style))
        .disabled(!enabled || busy)
    }
}

struct HostAgentMark: View {
    let client: HostMCPClient

    var body: some View {
        Group {
            if let name = Self.logoName(client), let image = HostSidebarLogo.image(named: name) {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
                    .padding(UIScale.pt(1))
            } else {
                EdithIconView(.code).font(.system(size: UIScale.pt(16), weight: .medium))
            }
        }
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }

    static func logoName(_ client: HostMCPClient) -> String? {
        switch client {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        case .vscode: nil
        }
    }
}

extension HostMCPInstaller.Connection {
    var title: String {
        switch self {
        case .connected: "Connected"
        case .notConnected: "Not connected"
        case .otherEdith: "Points at another Edith"
        case .manual: "Needs manual setup"
        }
    }
}
