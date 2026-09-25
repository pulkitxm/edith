import EdithKit
import GhosttyTerminal
import SwiftTerm
import SwiftUI

private struct HerdrResizeCursor: NSViewRepresentable {
    var axis = Axis.horizontal

    func makeNSView(context: Context) -> NSView {
        let view = CursorView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CursorView)?.cursor = cursor
    }

    private var cursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private final class CursorView: NSView {
        var cursor = NSCursor.resizeLeftRight

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
            cursor.set()
        }

        override func mouseEntered(with event: NSEvent) {
            cursor.set()
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

enum HerdrAgentTerminalOverlay: Equatable {
    case none
    case progress
    case failure(String)
    case ended(String)

    static func make(
        connectError: String?, starting: Bool, started: Bool, exitMessage: String?
    ) -> Self {
        if let connectError { return .failure(connectError) }
        if starting, !started { return .progress }
        if let exitMessage, !started { return .ended(exitMessage) }
        return .none
    }

    var offersRestart: Bool {
        if case .ended = self { return true }
        return false
    }
}

struct HerdrResizeHandle: View {
    var axis = Axis.horizontal
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
        let thickness = active ? UIScale.pt(3) : 1
        let horizontal = axis == .horizontal
        ZStack {
            Rectangle()
                .fill(active ? DashSkin.accent(dark) : DashSkin.lineStrong(dark).opacity(0.35))
                .frame(width: horizontal ? thickness : nil, height: horizontal ? nil : thickness)
        }
        .frame(width: horizontal ? UIScale.pt(9) : nil, height: horizontal ? nil : UIScale.pt(9))
        .frame(maxWidth: horizontal ? nil : .infinity, maxHeight: horizontal ? .infinity : nil)
        .contentShape(Rectangle())
        .background(HerdrResizeCursor(axis: axis))
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: active)
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    onChanged(horizontal ? value.translation.width : value.translation.height)
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
    var showsDetails = true
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
    @State private var splitTerminalFocus = HerdrTerminalFocus.agent

    private var dark: Bool { scheme == .dark }
    private var agent: HerdrAgent { tab.agent }

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
            if showsDetails, store.detailOpen {
                HerdrDetailColumn(
                    store: store, tab: tab, hideAgents: hideAgents, onSetView: onSetView)
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
            TerminalDropTransferStatus(holder: tab.holder)
            agentTerminalOverlay
        }
        .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
        .presenterCover(hideAgents, dark: dark)
    }

    @ViewBuilder
    private var agentTerminalOverlay: some View {
        switch HerdrAgentTerminalOverlay.make(
            connectError: connectError, starting: starting, started: tab.holder.started,
            exitMessage: tab.holder.exitMessage)
        {
        case .none:
            EmptyView()
        case .progress:
            HerdrAgentTerminalSkeleton(
                kind: agent.kind,
                palette: .edith(dark: dark)
            )
        case .failure(let message):
            Text(message)
                .font(.system(size: UIScale.pt(13)))
                .foregroundStyle(DashSkin.warn)
                .padding(UIScale.pt(16))
        case .ended(let message):
            VStack(spacing: UIScale.pt(10)) {
                Text(message)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Button("Restart") { Task { await startIfNeeded() } }
                    .buttonStyle(.edith(.primary))
                    .disabled(!launchEnabled)
            }
            .padding(UIScale.pt(20))
        }
    }

    private func handleRemoteDrop(_ payload: TerminalDropPayload) -> Bool {
        Task {
            await tab.holder.deliverRemoteDrop(payload) { files in
                try await store.uploadDroppedFiles(files, for: tab)
            }
        }
        return true
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
                TerminalLoadingSkeleton(palette: palette)
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

    private func startIfNeeded() async {
        guard launchEnabled, !tab.holder.started else { return }
        connectError = nil
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
