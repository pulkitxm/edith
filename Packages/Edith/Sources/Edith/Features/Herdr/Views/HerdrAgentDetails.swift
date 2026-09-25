import EdithKit
import SwiftUI

struct HerdrDetailColumn: View {
    var store: HerdrStore
    let tab: HerdrOpenTab
    var hideAgents = false
    var onSetView: ((HerdrAgentView) -> Void)?
    @State private var detailDragBaseWidth: Double?
    @State private var liveDetailWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            HerdrResizeHandle(
                label: "Resize the agent details",
                onChanged: resizeDetail,
                onEnded: finishDetailResize,
                onReset: resetDetailWidth)
            HerdrAgentDetails(
                store: store, tab: tab, hideAgents: hideAgents, onSetView: onSetView
            )
            .id(tab.id)
            .frame(width: detailDisplayWidth)
        }
    }

    private var detailDisplayWidth: Double {
        UIScale.pt(HerdrPaneSizing.detail(liveDetailWidth ?? store.detailWidth))
    }

    private func resizeDetail(_ translation: CGFloat) {
        let base = detailDragBaseWidth ?? detailDisplayWidth
        detailDragBaseWidth = base
        liveDetailWidth = HerdrPaneSizing.detail(
            (base - translation) / UIScale.current)
    }

    private func finishDetailResize() {
        if let liveDetailWidth { store.detailWidth = liveDetailWidth }
        liveDetailWidth = nil
        detailDragBaseWidth = nil
    }

    private func resetDetailWidth() {
        liveDetailWidth = nil
        detailDragBaseWidth = nil
        store.detailWidth = HerdrPaneSizing.detailDefault
    }
}

struct HerdrAgentDetails: View {
    var store: HerdrStore
    let tab: HerdrOpenTab
    var hideAgents = false
    var onSetView: ((HerdrAgentView) -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var confirmingAgentClose = false
    @State private var closingAgent = false
    @State private var agentCloseError: String?

    private var dark: Bool { scheme == .dark }
    private var agent: HerdrAgent { tab.agent }
    private var command: String { HerdrAttachCommand.line(for: agent) }

    var body: some View { sidebar }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                    Text(agent.title)
                        .font(DashSkin.heading(20))
                        .foregroundStyle(DashSkin.ink(dark))
                        .padding(.trailing, UIScale.pt(36))
                        .presenterTextBlur(hideAgents, fontSize: 20)
                    if !agent.isTerminal { viewSection }
                    kindRow
                    if !agent.isTerminal { metaRow("Status", agent.status.title) }
                    metaRow("Machine", agent.machineName)
                    if !agent.session.isEmpty {
                        metaRow("Session", agent.session, blur: hideAgents)
                    }
                    if !agent.pane.isEmpty { metaRow("Pane", agent.pane, blur: hideAgents) }
                    if !agent.workspace.isEmpty {
                        metaRow("Workspace", agent.workspace, blur: hideAgents)
                    }
                    if !agent.cwd.isEmpty { metaRow("Directory", agent.cwd, blur: hideAgents) }
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        Text("Attach")
                            .font(.system(size: UIScale.pt(11), weight: .semibold))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Text(command)
                            .font(DashSkin.mono(10))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .textSelection(.enabled)
                            .presenterTextBlur(hideAgents, fontSize: 10)
                        Button {
                            store.copyAttachCommand(for: agent)
                        } label: {
                            Label(
                                store.copiedID == agent.id
                                    ? "Copied"
                                    : (agent.machineIsLocal || agent.isTerminal
                                        ? "Copy command" : "Copy SSH"),
                                systemImage: store.copiedID == agent.id
                                    ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.edith(.toolbar))
                    }
                }
                .padding(UIScale.pt(16))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !agent.isTerminal { closeAgentFooter }
        }
        .background(DashSkin.paper(dark))
        .confirmationDialog(
            "Close this agent?", isPresented: $confirmingAgentClose,
            titleVisibility: .visible
        ) {
            Button("Close Agent", role: .destructive) {
                Task { await closeAgent() }
            }
        } message: {
            Text("The agent exits gracefully, then its Herdr pane closes.")
        }
        .alert("Could not close agent", isPresented: agentCloseFailed) {
            Button("OK") { agentCloseError = nil }
        } message: {
            Text(agentCloseError ?? "Herdr could not close the agent.")
        }
    }

    private var closeAgentFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: 1)
            Button {
                confirmingAgentClose = true
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    if closingAgent {
                        SkeletonGroup {
                            SkeletonBlock(width: 12, height: 12, corner: 6)
                        }
                        .accessibilityLabel("Closing agent")
                    } else {
                        Image(systemName: "xmark.circle.fill")
                    }
                    Text(closingAgent ? "Closing Agent" : "Close Agent")
                }
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, UIScale.pt(9))
                .background(Color.red.opacity(dark ? 0.78 : 0.86))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
            }
            .buttonStyle(.edith(.borderless))
            .disabled(closingAgent)
            .help("Close the agent and its Herdr pane")
            .padding(UIScale.pt(12))
        }
        .background(DashSkin.paper2(dark))
    }

    private var agentCloseFailed: Binding<Bool> {
        Binding(
            get: { agentCloseError != nil },
            set: { if !$0 { agentCloseError = nil } })
    }

    private func closeAgent() async {
        closingAgent = true
        defer { closingAgent = false }
        do {
            try await store.closeAgent(agent)
        } catch {
            agentCloseError = error.localizedDescription
        }
    }

    private var viewSection: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Text("View")
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            HerdrAgentViewToggle(selection: tab.view) { option in
                if let onSetView {
                    onSetView(option)
                } else {
                    store.setView(option, for: tab.id)
                }
            }
            if tab.view.showsDiff, let branch = tab.quinjet.branch {
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
                Text(agent.isTerminal ? HerdrMachineTerminal.title : agent.kind)
                    .font(.system(size: UIScale.pt(12.5)))
                    .textSelection(.enabled)
            }
            .foregroundStyle(DashSkin.ink(dark))
        }
    }

    private func metaRow(_ label: String, _ value: String, blur: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(label)
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .textSelection(.enabled)
                .presenterTextBlur(blur, fontSize: 12.5)
        }
    }
}
