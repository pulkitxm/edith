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
    @AppStorage(AppStorageKeys.Herdr.terminalFontSize, store: SharedDefaults.store)
    private var fontSize = HerdrTerminalSettings.fontSizeDefault
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
                        .presenterCover(hideAgents, dark: dark)
                    Rectangle()
                        .fill(DashSkin.lineStrong(dark))
                        .frame(width: 1)
                    HerdrTerminalList(store: store, owner: owner, hideAgents: hideAgents)
                        .frame(width: UIScale.pt(HerdrTerminalPanelSizing.listWidth))
                }
            }
            .frame(height: displayHeight)
            .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
            .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: UIScale.pt(14), y: -2)
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
        let size = HerdrTerminalSettings.clampedFontSize(fontSize)
        return ZStack {
            ForEach(panels.terminals(of: owner)) { terminal in
                let selected = terminal.id == selectedID
                HerdrPanelTerminalView(
                    store: store, terminal: terminal, selected: selected,
                    wantsFocus: selected && panels.holdsFocus(owner),
                    launchEnabled: launchEnabled, fontSize: size,
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
        let height = panels.maximized ? maximum : liveHeight ?? panels.height
        return UIScale.pt(HerdrTerminalPanelSizing.height(height, maximum: maximum))
    }

    private func resize(_ translation: CGFloat) {
        let base = dragBaseHeight ?? displayHeight
        dragBaseHeight = base
        panels.maximized = false
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
        panels.maximized = false
        panels.height = HerdrTerminalPanelSizing.heightDefault
    }
}

private struct HerdrTerminalList: View {
    var store: HerdrStore
    let owner: String
    let hideAgents: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var settingsOpen = false

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
        HStack(spacing: UIScale.pt(2)) {
            Text("Terminals")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Spacer(minLength: 0)
            newTerminalButton
            iconButton("gearshape", label: "Terminal settings") {
                settingsOpen.toggle()
            }
            .popover(isPresented: $settingsOpen, arrowEdge: .top) {
                HerdrTerminalSettingsView()
            }
            iconButton(
                panels.maximized
                    ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: panels.maximized ? "Restore the terminal height" : "Fill the tab"
            ) {
                panels.maximized.toggle()
            }
            iconButton("chevron.down", label: "Hide terminals") {
                panels.hide(owner)
            }
        }
        .padding(.leading, UIScale.pt(10))
        .padding(.trailing, UIScale.pt(4))
        .frame(height: UIScale.pt(30))
    }

    @ViewBuilder
    private var newTerminalButton: some View {
        let origins = store.terminalOrigins(for: owner)
        if origins.count > 1 {
            Menu {
                Section("New terminal for") {
                    ForEach(origins) { origin in
                        Button(
                            hideAgents ? origin.location : "\(origin.title) · \(origin.location)"
                        ) {
                            store.openTerminal(in: owner, from: origin)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(width: UIScale.pt(18), height: UIScale.pt(18))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("New terminal")
        } else if let origin = origins.first {
            iconButton("plus", label: "New terminal") {
                store.openTerminal(in: owner, from: origin)
            }
        }
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
                        Text(terminal.location)
                            .font(DashSkin.mono(9))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .presenterTextBlur(hideAgents, fontSize: 9)
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
            .accessibilityLabel("\(terminal.title), \(terminal.location)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            iconButton("xmark", label: "Close \(terminal.title)") {
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

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void)
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
        .accessibilityLabel(label)
    }
}

struct HerdrTerminalSettingsView: View {
    @AppStorage(AppStorageKeys.Herdr.terminalMouse, store: SharedDefaults.store)
    private var mouse = HerdrTerminalMouse.scroll
    @AppStorage(AppStorageKeys.Herdr.terminalFontSize, store: SharedDefaults.store)
    private var fontSize = HerdrTerminalSettings.fontSizeDefault
    @AppStorage(AppStorageKeys.Herdr.terminalStartFolder, store: SharedDefaults.store)
    private var startFolder = HerdrTerminalSettings.StartFolder.agent
    @AppStorage(AppStorageKeys.Herdr.terminalStartupCommand, store: SharedDefaults.store)
    private var startupCommand = ""
    @AppStorage(AppStorageKeys.Herdr.terminalConfirmClose, store: SharedDefaults.store)
    private var confirmClose = true

    var body: some View {
        Form {
            Section {
                Picker("Mouse", selection: $mouse) {
                    ForEach(HerdrTerminalMouse.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Stepper(value: $fontSize, in: HerdrTerminalSettings.fontSizeRange, step: 1) {
                    LabeledContent(
                        "Text size",
                        value: "\(Int(HerdrTerminalSettings.clampedFontSize(fontSize))) pt")
                }
            } footer: {
                Text(
                    mouse == .scroll
                        ? "The wheel scrolls. Clicks and pointer moves never reach the shell."
                        : "The wheel scrolls, and clicks reach apps that use the mouse, like vim."
                )
                .settingsCaption()
            }
            Section {
                Picker("Start in", selection: $startFolder) {
                    ForEach(HerdrTerminalSettings.StartFolder.allCases, id: \.self) { folder in
                        Text(folder.title).tag(folder)
                    }
                }
                TextField("Startup command", text: $startupCommand, prompt: Text("None"))
                Toggle("Ask before closing a tab with running terminals", isOn: $confirmClose)
            }
        }
        .formStyle(.grouped)
        .frame(width: UIScale.pt(380))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HerdrPanelTerminalView: View {
    var store: HerdrStore
    let terminal: HerdrPanelTerminal
    let selected: Bool
    let wantsFocus: Bool
    let launchEnabled: Bool
    let fontSize: Double
    let onFocus: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppStorageKeys.Herdr.terminalMouse, store: SharedDefaults.store)
    private var mouse = HerdrTerminalMouse.scroll
    @State private var starting = false
    @State private var startedMouse: HerdrTerminalMouse?

    private var dark: Bool { scheme == .dark }
    private var palette: TerminalPalette { .edith(dark: dark) }

    var body: some View {
        ZStack {
            TerminalPane(
                holder: terminal.holder, palette: palette, active: selected,
                wantsFocus: wantsFocus, fontSize: fontSize,
                onDropFiles: terminal.host.isLocal ? nil : handleRemoteDrop,
                onFocus: onFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TerminalDropTransferStatus(holder: terminal.holder)
            overlay
        }
        .background(Color(nsColor: palette.background))
        .task(id: "\(terminal.pane ?? "")|\(mouse.rawValue)") { await start() }
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
        guard launchEnabled, terminal.pane != nil else { return }
        if terminal.holder.started {
            guard let startedMouse, startedMouse != mouse else { return }
            terminal.holder.stop()
        }
        starting = true
        defer { starting = false }
        do {
            let request = try await store.attachRequest(
                for: terminal,
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
            guard !terminal.holder.started else { return }
            terminal.holder.start(
                executable: request.executable, arguments: request.arguments,
                environment: request.environment,
                allowsLocalFileLinks: terminal.host.isLocal)
            startedMouse = mouse
        } catch {
            store.terminalPanels.fail(terminal.id, error.localizedDescription)
        }
    }
}
