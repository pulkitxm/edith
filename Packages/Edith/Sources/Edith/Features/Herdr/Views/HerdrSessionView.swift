import EdithKit
import GhosttyTerminal
import SwiftTerm
import SwiftUI

private struct HerdrResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.activeInActiveApp, .cursorUpdate, .mouseEnteredAndExited],
                    owner: self))
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }
    }
}

private enum HerdrTerminalFocus {
    case agent
    case diff
}

struct HerdrHorizontalResizeHandle: View {
    let label: String
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onReset: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var dragging = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let active = hovered || dragging
        ZStack {
            Rectangle()
                .fill(active ? DashSkin.accent(dark) : DashSkin.lineStrong(dark).opacity(0.35))
                .frame(width: active ? UIScale.pt(3) : 1)
        }
        .frame(width: UIScale.pt(9))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(HerdrResizeCursor())
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: active)
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    onChanged(value.translation.width)
                }
                .onEnded { _ in
                    dragging = false
                    onEnded()
                }
        )
        .onTapGesture(count: 2) { onReset() }
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

struct HerdrSessionView: View {
    var store: HerdrStore
    let tab: HerdrOpenTab
    let launchEnabled: Bool
    var hideAgents = false
    var presented = true
    var wantsFocus = true
    var onFocus: (() -> Void)?
    var onSetView: ((HerdrAgentView) -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.Quinjet.theme, store: SharedDefaults.store)
    private var quinjetThemeName = QuinjetThemePreference.app
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var appThemeName = AppTheme.accent.rawValue
    @State private var connectError: String?
    @State private var starting = false
    @State private var dragWidth: CGFloat?
    @State private var handleHovered = false
    @State private var transferringDrop = false
    @State private var dropError: String?
    @State private var detailDragBaseWidth: Double?
    @State private var liveDetailWidth: Double?
    @State private var confirmingAgentClose = false
    @State private var closingAgent = false
    @State private var agentCloseError: String?
    @State private var splitTerminalFocus = HerdrTerminalFocus.agent

    private var dark: Bool { scheme == .dark }
    private var agent: HerdrAgent { tab.agent }
    private var command: String { HerdrAttachCommand.line(for: agent) }

    private var terminalFocus: HerdrTerminalFocus {
        switch tab.view {
        case .agent: .agent
        case .diff: .diff
        case .split: splitTerminalFocus
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.detailOpen {
                HerdrHorizontalResizeHandle(
                    label: "Resize the agent details",
                    onChanged: resizeDetail,
                    onEnded: finishDetailResize,
                    onReset: resetDetailWidth)
                sidebar
                    .frame(width: detailDisplayWidth)
            }
        }
        .task(id: tab.id) { await startIfNeeded() }
        .task(id: diffRequest) { await prepareDiffIfNeeded() }
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

    @ViewBuilder
    private var content: some View {
        if tab.view == .split, !agent.isTerminal {
            GeometryReader { proxy in
                let total = proxy.size.width
                HStack(spacing: 0) {
                    sessionPane
                        .frame(width: sessionWidth(in: total))
                    splitHandle(total: total)
                    diffPane
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) { ghost(in: total) }
            }
        } else {
            ZStack {
                sessionPane
                    .opacity(tab.view == .agent ? 1 : 0)
                    .allowsHitTesting(tab.view == .agent)
                diffPane
                    .opacity(tab.view == .diff ? 1 : 0)
                    .allowsHitTesting(tab.view == .diff)
            }
        }
    }

    private var handleWidth: CGFloat { UIScale.pt(11) }

    private func paneWidth(in total: CGFloat, fraction: Double) -> CGFloat {
        let minimum = UIScale.pt(220)
        guard total > minimum * 2 + handleWidth else {
            return max(0, (total - handleWidth) / 2)
        }
        return min(total - minimum - handleWidth, max(minimum, total * fraction))
    }

    private func sessionWidth(in total: CGFloat) -> CGFloat {
        paneWidth(in: total, fraction: store.splitFraction(for: tab.id))
    }

    private func draggedWidth(translation: CGFloat, in total: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let base = store.splitFraction(for: tab.id)
        let moved = HerdrSplitFraction.clamp(base + Double(translation / total))
        return paneWidth(in: total, fraction: moved)
    }

    @ViewBuilder
    private func ghost(in total: CGFloat) -> some View {
        if let dragWidth {
            Rectangle()
                .fill(DashSkin.accent(dark))
                .frame(width: UIScale.pt(2))
                .frame(maxHeight: .infinity)
                .offset(x: dragWidth + (handleWidth - UIScale.pt(2)) / 2)
                .allowsHitTesting(false)
        }
    }

    private func splitHandle(total: CGFloat) -> some View {
        let active = handleHovered || dragWidth != nil
        return ZStack {
            Capsule()
                .fill(active ? DashSkin.accent(dark) : DashSkin.lineStrong(dark))
                .frame(width: active ? UIScale.pt(3) : 1)
                .padding(.vertical, active ? UIScale.pt(6) : 0)
        }
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(HerdrResizeCursor())
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: active)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragWidth = draggedWidth(translation: value.translation.width, in: total)
                }
                .onEnded { value in
                    guard total > 0 else {
                        dragWidth = nil
                        return
                    }
                    let base = store.splitFraction(for: tab.id)
                    store.setSplitFraction(
                        HerdrSplitFraction.clamp(
                            base + Double(value.translation.width / total)),
                        for: tab.id)
                    dragWidth = nil
                }
        )
        .onHover { handleHovered = $0 }
        .accessibilityLabel("Resize the split")
    }

    private var diffRequest: String {
        "\(tab.id)|\(tab.view.rawValue)|\(dark)|\(quinjetThemeName)|\(appThemeName)"
    }

    private var sessionPane: some View {
        ZStack {
            TerminalPane(
                holder: tab.holder, palette: .edith(dark: dark),
                active: presented && tab.view.showsAgent,
                wantsFocus: wantsFocus && terminalFocus == .agent,
                onDropFiles: agent.machineIsLocal ? nil : handleRemoteDrop,
                onFocus: {
                    splitTerminalFocus = .agent
                    onFocus?()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if transferringDrop {
                ProgressView()
                    .controlSize(.small)
                    .padding(UIScale.pt(10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let dropError {
                Text(dropError)
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                    .foregroundStyle(DashSkin.warn)
                    .padding(UIScale.pt(10))
                    .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
                    .padding(UIScale.pt(10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            if let connectError {
                Text(connectError)
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(DashSkin.warn)
                    .padding(UIScale.pt(16))
            } else if starting, !tab.holder.started {
                ProgressView()
            }
        }
        .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
        .presenterCover(hideAgents, dark: dark)
    }

    private func handleRemoteDrop(_ payload: TerminalDropPayload) -> Bool {
        Task { await transferRemoteDrop(payload) }
        return true
    }

    private func transferRemoteDrop(_ payload: TerminalDropPayload) async {
        transferringDrop = true
        dropError = nil
        defer {
            transferringDrop = false
            payload.removeTemporaryFiles()
        }
        do {
            let paths = try await store.uploadDroppedFiles(payload.files, for: tab)
            tab.holder.insertText(paths.map(ShellQuote.quote).joined(separator: " "))
        } catch {
            dropError = error.localizedDescription
        }
    }

    private var diffPane: some View {
        let palette = TerminalPalette.quinjet(configuration: diffConfiguration)
        return ZStack {
            Color(nsColor: palette.background)
            TerminalPane(
                holder: tab.quinjet.holder, palette: palette,
                active: presented && tab.view.showsDiff && tab.quinjet.live,
                wantsFocus: wantsFocus && terminalFocus == .diff,
                onFocus: {
                    splitTerminalFocus = .diff
                    onFocus?()
                }
            )
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
        }
        .padding(UIScale.pt(28))
        .frame(maxWidth: UIScale.pt(420))
    }

    private var diffConfiguration: QuinjetLaunchConfiguration {
        store.quinjetConfiguration(appearance: dark ? .dark : .light)
    }

    private func prepareDiffIfNeeded() async {
        guard tab.view.showsDiff else { return }
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                    Text(agent.title)
                        .font(DashSkin.serif(20))
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
            Text("The agent process will exit. Its terminal pane will remain open.")
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
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
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
            .help("Close the agent and keep its terminal pane open")
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

    private func startIfNeeded() async {
        guard launchEnabled, !tab.holder.started else { return }
        starting = true
        defer { starting = false }
        do {
            let request = try await store.attachRequest(
                for: tab,
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
            tab.holder.start(
                executable: request.executable, arguments: request.arguments,
                environment: request.environment,
                allowsLocalFileLinks: tab.agent.machineIsLocal)
        } catch {
            connectError = error.localizedDescription
        }
    }
}
