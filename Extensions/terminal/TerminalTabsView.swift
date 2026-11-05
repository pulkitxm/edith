import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct TerminalTabsView: View {
    let model: TerminalTabsModel
    var presented = true
    var onWindowClose: () -> Void = {}
    var onWindowShow: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @State private var command = ""
    @State private var broadcastError: String?
    @State private var showsSettings = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.3)
            ZStack {
                ForEach(model.tabs) { tab in
                    TerminalSessionView(
                        holder: tab.holder, active: presented && tab.id == model.selected,
                        restart: { model.restart(tab.id) }
                    )
                    .opacity(tab.id == model.selected ? 1 : 0)
                    .allowsHitTesting(tab.id == model.selected)
                }
                if model.tabs.isEmpty {
                    PageEmptyState(
                        icon: .terminal,
                        title: "No terminals open",
                        message:
                            "A terminal gives you a real shell inside Edith, starting in your home folder. Closing a tab ends only that shell.",
                        primary: PageAction(
                            "New Terminal", icon: .plus, identifier: "terminal.empty.new"
                        ) { model.addTab() },
                        footnote: "Press ⌘T to open a terminal and ⌘W to close the current one."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.broadcast { broadcastBar }
            if let error = model.error {
                TerminalStatusBar(
                    icon: .warning, message: error,
                    tint: DashSkin.danger)
            }
        }
        .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
        .background(shortcuts)
        .background(TerminalWindowObserver(onShow: onWindowShow, onClose: onWindowClose))
        .onAppear {
            model.presented = presented
            if presented { model.ensureFirstTab() }
        }
        .onChange(of: presented) { _, visible in
            model.presented = visible
            if visible { model.ensureFirstTab() }
        }
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { model.addTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("") {
                if let selected = model.selected { model.closeTab(selected) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("") {
                if let selected = model.selected { model.closeTab(selected) }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("") { model.selectNext(backwards: false) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("") { model.selectNext(backwards: true) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var tabBar: some View {
        HStack(spacing: UIScale.pt(4)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(4)) {
                    ForEach(model.tabs) { tab in tabButton(tab) }
                }
            }
            Button {
                model.addTab()
            } label: {
                EdithIconView(.plus)
            }
            .buttonStyle(.edith(.toolbar))
            .help(
                model.tabs.count >= TerminalTabsModel.maximumTabs
                    ? "Close a tab to open another (limit \(TerminalTabsModel.maximumTabs))"
                    : "New terminal (⌘T)"
            )
            .accessibilityLabel("New terminal")
            .disabled(model.tabs.count >= TerminalTabsModel.maximumTabs)

            Toggle("Broadcast", isOn: Bindable(model).broadcast)
                .toggleStyle(.checkbox)
                .font(.edithText(.callout))
                .padding(.horizontal, UIScale.pt(4))
                .help("Type once, send to every tab. A bar appears below to type the command.")

            Button {
                showsSettings.toggle()
            } label: {
                EdithIconView(.gear)
            }
            .buttonStyle(.edith(.toolbar))
            .help("Terminal settings")
            .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                TerminalSettingsView(model: model)
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
        .background(.thinMaterial)
    }

    private func tabButton(_ tab: TerminalTabsModel.Tab) -> some View {
        Button {
            model.select(tab.id)
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                EdithIconView(.terminal)
                    .font(.edithText(.caption))
                Text(tab.displayTitle)
                    .font(.edithText(.callout)).fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: UIScale.pt(220))
                if model.tabs.count > 1 {
                    Button {
                        model.closeTab(tab.id)
                    } label: {
                        EdithIconView(.close)
                            .font(.edithText(.caption2)).fontWeight(.bold)
                            .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.edith(.borderless))
                    .accessibilityLabel("Close \(tab.displayTitle)")
                }
            }
            .foregroundStyle(
                tab.id == model.selected ? DashSkin.ink(dark) : DashSkin.inkFaint(dark)
            )
            .padding(.horizontal, UIScale.pt(12))
            .frame(minHeight: UIScale.pt(PageMetrics.chipHeight))
            .background(
                tab.id == model.selected ? DashSkin.paper2(dark) : .clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(PageMetrics.chipCornerRadius))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
    }

    private var broadcastBar: some View {
        HStack(spacing: UIScale.pt(8)) {
            EdithIconView(.signal)
                .foregroundStyle(DashSkin.warn)
                .accessibilityHidden(true)
            TextField("Type a command to run in every tab", text: $command)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendBroadcast)
            Button("Send to All", action: sendBroadcast)
                .buttonStyle(.edith(.primary))
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            if let broadcastError {
                Text(broadcastError)
                    .font(.edithText(.callout))
                    .foregroundStyle(DashSkin.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
        .background(DashSkin.warn.opacity(0.1))
    }

    private func sendBroadcast() {
        switch TerminalBroadcastPlan.make(command: command) {
        case let .failure(error):
            broadcastError = error.localizedDescription
        case let .success(plan):
            Task { @MainActor in
                do {
                    let delivery = try await model.sendBroadcast(plan)
                    if let message = delivery.failureMessage, !delivery.isComplete {
                        broadcastError = message
                        return
                    }
                    command = ""
                    broadcastError = nil
                } catch { broadcastError = "The owned terminal engine is unavailable." }
            }
        }
    }
}

struct TerminalWindowObserver: NSViewRepresentable {
    let onShow: () -> Void
    let onClose: () -> Void

    final class ObserverView: NSView {
        var onShow: () -> Void = {}
        var onClose: () -> Void = {}
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose() }
                },
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onShow() }
                },
            ]
        }

        override func removeFromSuperview() {
            removeObservers()
            super.removeFromSuperview()
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onShow = onShow
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onShow = onShow
        view.onClose = onClose
    }
}
