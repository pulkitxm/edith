import EdithKit
import SwiftTerm
import SwiftUI

private struct SplitResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
    }
}

struct HerdrSessionView: View {
    var store: HerdrStore
    let tab: HerdrOpenTab
    let launchEnabled: Bool
    var hideAgents = false
    var presented = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var connectError: String?
    @State private var starting = false
    @State private var dragWidth: CGFloat?
    @State private var handleHovered = false

    private var dark: Bool { scheme == .dark }
    private var agent: HerdrAgent { tab.agent }
    private var command: String { HerdrAttachCommand.line(for: agent) }

    var body: some View {
        HStack(spacing: 0) {
            content
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
        .background(SplitResizeCursor())
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
        "\(tab.id)|\(tab.view.rawValue)|\(dark)"
    }

    private var sessionPane: some View {
        ZStack {
            TerminalPane(
                holder: tab.holder, palette: .edith(dark: dark),
                active: presented && tab.view.showsAgent
            )
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
            TerminalPane(
                holder: tab.quinjet.holder, palette: palette,
                active: presented && tab.view.showsDiff && tab.quinjet.live
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
            .pointerCursor()
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
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                Text(hideAgents ? "Hidden" : agent.title)
                    .font(DashSkin.serif(20))
                    .foregroundStyle(hideAgents ? DashSkin.inkFaint(dark) : DashSkin.ink(dark))
                    .padding(.trailing, UIScale.pt(36))
                if !agent.isTerminal { viewSection }
                kindRow
                if !agent.isTerminal { metaRow("Status", agent.status.title) }
                metaRow("Machine", agent.machineName)
                if !hideAgents {
                    if !agent.session.isEmpty { metaRow("Session", agent.session) }
                    if !agent.pane.isEmpty { metaRow("Pane", agent.pane) }
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
                                    : (agent.machineIsLocal || agent.isTerminal
                                        ? "Copy command" : "Copy SSH"),
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
        do {
            let request = try await store.attachRequest(
                for: tab,
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
            tab.holder.start(
                executable: request.executable, arguments: request.arguments,
                environment: request.environment)
        } catch {
            connectError = error.localizedDescription
        }
    }
}
