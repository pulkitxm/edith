import EdithKit
import GhosttyTerminal
import SwiftTerm
import SwiftUI

struct HerdrTerminalPanelView: View {
    var store: HerdrStore
    let owner: String
    let launchEnabled: Bool
    let maximumHeight: CGFloat
    var hideAgents = false
    @Environment(\.colorScheme) private var scheme
    @State private var dragBaseHeight: Double?
    @State private var liveHeight: Double?

    private var dark: Bool { scheme == .dark }
    private var panels: HerdrTerminalPanels { store.terminalPanels }

    var body: some View {
        if panels.isOpen(owner) {
            VStack(spacing: 0) {
                HerdrResizeHandle(
                    axis: .vertical, label: "Resize the terminals",
                    onChanged: resize, onEnded: finishResize, onReset: resetHeight)
                HStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle()
                        .fill(DashSkin.lineStrong(dark))
                        .frame(width: 1)
                    HerdrTerminalList(store: store, owner: owner, hideAgents: hideAgents)
                        .frame(width: UIScale.pt(HerdrTerminalPanelSizing.listWidth))
                }
            }
            .frame(height: displayHeight)
            .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
            .task(id: owner) {
                while !Task.isCancelled {
                    await panels.refresh(owner)
                    try? await Task.sleep(for: HerdrTerminalPanelSizing.refreshInterval)
                }
            }
        }
    }

    private var content: some View {
        let selectedID = panels.selectedID(in: owner)
        return ZStack {
            ForEach(panels.terminals(of: owner)) { terminal in
                let selected = terminal.id == selectedID
                HerdrPanelTerminalView(
                    store: store, terminal: terminal, selected: selected,
                    wantsFocus: selected && panels.holdsFocus(owner),
                    launchEnabled: launchEnabled,
                    onFocus: { panels.focus(owner) }
                )
                .opacity(selected ? 1 : 0)
                .allowsHitTesting(selected)
            }
        }
    }

    private var maximum: Double {
        Double(maximumHeight) / UIScale.current
    }

    private var displayHeight: Double {
        UIScale.pt(
            HerdrTerminalPanelSizing.height(liveHeight ?? panels.height, maximum: maximum))
    }

    private func resize(_ translation: CGFloat) {
        let base = dragBaseHeight ?? displayHeight
        dragBaseHeight = base
        liveHeight = HerdrTerminalPanelSizing.height(
            (base - translation) / UIScale.current, maximum: maximum)
    }

    private func finishResize() {
        if let liveHeight { panels.height = liveHeight }
        liveHeight = nil
        dragBaseHeight = nil
    }

    private func resetHeight() {
        liveHeight = nil
        dragBaseHeight = nil
        panels.height = HerdrTerminalPanelSizing.heightDefault
    }
}

private struct HerdrTerminalList: View {
    var store: HerdrStore
    let owner: String
    let hideAgents: Bool
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var panels: HerdrTerminalPanels { store.terminalPanels }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(DashSkin.lineStrong(dark))
                .frame(height: 1)
            ScrollView {
                VStack(spacing: UIScale.pt(2)) {
                    ForEach(panels.terminals(of: owner)) { terminal in
                        row(terminal)
                    }
                }
                .padding(UIScale.pt(6))
            }
        }
        .background(DashSkin.paper2(dark))
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(4)) {
            Text("Terminals")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Spacer(minLength: 0)
            iconButton("plus", help: "New terminal (⌃⇧`)") {
                store.perform(.new)
            }
            iconButton("chevron.down", help: "Hide terminals (⌘J)") {
                panels.hide(owner)
            }
        }
        .padding(.leading, UIScale.pt(10))
        .padding(.trailing, UIScale.pt(6))
        .frame(height: UIScale.pt(30))
    }

    private func row(_ terminal: HerdrPanelTerminal) -> some View {
        let selected = panels.selectedID(in: owner) == terminal.id
        return HStack(spacing: UIScale.pt(4)) {
            Button {
                panels.select(terminal.id, in: owner)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: "terminal")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(
                            terminal.running
                                ? HerdrStatusColor.color(.working, dark: dark)
                                : DashSkin.inkFaint(dark))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(terminal.title)
                            .font(
                                .system(
                                    size: UIScale.pt(12), weight: selected ? .semibold : .medium)
                            )
                            .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !terminal.host.isLocal {
                            Text(terminal.host.machineName)
                                .font(DashSkin.mono(9))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                                .presenterTextBlur(hideAgents, fontSize: 9)
                        }
                    }
                    Spacer(minLength: 0)
                    if terminal.running {
                        Circle()
                            .fill(HerdrStatusColor.color(.working, dark: dark))
                            .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                            .accessibilityLabel("Running")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(terminal.process?.command ?? terminal.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            iconButton("xmark", help: "Close \(terminal.title)") {
                panels.close(terminal.id)
            }
        }
        .padding(.leading, UIScale.pt(8))
        .padding(.trailing, UIScale.pt(4))
        .padding(.vertical, UIScale.pt(5))
        .background(
            RoundedRectangle(cornerRadius: UIScale.pt(6))
                .fill(selected ? DashSkin.accent(dark).opacity(0.16) : Color.clear))
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(18), height: UIScale.pt(18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct HerdrPanelTerminalView: View {
    var store: HerdrStore
    let terminal: HerdrPanelTerminal
    let selected: Bool
    let wantsFocus: Bool
    let launchEnabled: Bool
    let onFocus: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var starting = false

    private var dark: Bool { scheme == .dark }
    private var palette: TerminalPalette { .edith(dark: dark) }

    var body: some View {
        ZStack {
            TerminalPane(
                holder: terminal.holder, palette: palette, active: selected,
                wantsFocus: wantsFocus,
                onDropFiles: terminal.host.isLocal ? nil : handleRemoteDrop,
                onFocus: onFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TerminalDropTransferStatus(holder: terminal.holder)
            overlay
        }
        .background(Color(nsColor: palette.background))
        .task(id: terminal.pane) { await start() }
    }

    @ViewBuilder
    private var overlay: some View {
        if let failure = terminal.failure {
            placeholder(failure, action: "Retry") {
                store.terminalPanels.retry(terminal.id)
                if terminal.pane != nil { Task { await start() } }
            }
        } else if terminal.pane == nil || (starting && !terminal.holder.started) {
            TerminalLoadingSkeleton(palette: palette)
        } else if let message = terminal.holder.exitMessage, !terminal.holder.started {
            placeholder(message, action: "Restart") {
                Task { await start() }
            }
        }
    }

    private func placeholder(_ message: String, action: String, perform: @escaping () -> Void)
        -> some View
    {
        VStack(spacing: UIScale.pt(10)) {
            Text(message)
                .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                .foregroundStyle(Color(nsColor: palette.foreground))
                .multilineTextAlignment(.center)
            Button(action, action: perform)
                .buttonStyle(.edith(.primary))
                .disabled(!launchEnabled)
        }
        .padding(UIScale.pt(20))
        .frame(maxWidth: UIScale.pt(420))
    }

    private func handleRemoteDrop(_ payload: TerminalDropPayload) -> Bool {
        let machine = terminal.host.machine
        Task {
            await terminal.holder.deliverRemoteDrop(payload) { files in
                try await store.uploadDroppedFiles(files, to: machine)
            }
        }
        return true
    }

    private func start() async {
        guard launchEnabled, terminal.pane != nil, !terminal.holder.started else { return }
        starting = true
        defer { starting = false }
        do {
            let request = try await store.attachRequest(
                for: terminal,
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
            terminal.holder.start(
                executable: request.executable, arguments: request.arguments,
                environment: request.environment,
                allowsLocalFileLinks: terminal.host.isLocal)
        } catch {
            store.terminalPanels.fail(terminal.id, error.localizedDescription)
        }
    }
}
