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
                    VStack(spacing: UIScale.pt(10)) {
                        Text("No terminals open.")
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Button("New terminal") { model.addTab() }
                            .buttonStyle(.edith(.primary))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.broadcast { broadcastBar }
            if let error = model.error {
                Text(error).font(.edithText(.caption)).foregroundStyle(DashSkin.danger).padding(
                    UIScale.pt(8))
            }
        }
        .background(Color(nsColor: TerminalPalette.edith(dark: dark).background))
        .background(shortcuts)
        .background(TerminalWindowObserver(onShow: onWindowShow, onClose: onWindowClose))
        .onAppear { if presented { model.ensureFirstTab() } }
        .onChange(of: presented) { _, visible in if visible { model.ensureFirstTab() } }
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { model.addTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("") {
                if let selected = model.selected { model.closeTab(selected) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
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
                Image(systemName: "plus")
            }
            .buttonStyle(.edith(.toolbar))
            .help("New terminal (⌘T)")
            .disabled(model.tabs.count >= TerminalTabsModel.maximumTabs)

            Toggle("Broadcast", isOn: Bindable(model).broadcast)
                .toggleStyle(.checkbox)
                .font(.system(size: UIScale.pt(10.5)))
                .help("Type once, send to every tab")

            Button {
                showsSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.edith(.toolbar))
            .help("Terminal settings")
            .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                TerminalSettingsView(model: model)
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(9))
        .background(.thinMaterial)
    }

    private func tabButton(_ tab: TerminalTabsModel.Tab) -> some View {
        Button {
            model.select(tab.id)
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "terminal")
                    .font(.system(size: UIScale.pt(9.5)))
                Text(tab.displayTitle)
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: UIScale.pt(220))
                if model.tabs.count > 1 {
                    Button {
                        model.closeTab(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: UIScale.pt(7.5), weight: .bold))
                    }
                    .buttonStyle(.edith(.borderless))
                    .accessibilityLabel("Close \(tab.displayTitle)")
                }
            }
            .foregroundStyle(
                tab.id == model.selected ? DashSkin.ink(dark) : DashSkin.inkFaint(dark)
            )
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(6))
            .background(
                tab.id == model.selected ? DashSkin.paper2(dark) : .clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
    }

    private var broadcastBar: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(DashSkin.warn)
            TextField("Send to every tab", text: $command)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendBroadcast)
            Button("Send", action: sendBroadcast)
            if let broadcastError {
                Text(broadcastError)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.danger)
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(7))
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
