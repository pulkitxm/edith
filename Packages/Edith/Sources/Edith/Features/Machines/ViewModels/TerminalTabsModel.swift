import AppKit
import EdithKit
import Observation
import SwiftTerm
import SwiftUI

@MainActor
@Observable
final class TerminalTabsModel {
    typealias UserCloseRequester =
        @MainActor (
            TerminalSessionHolder, @escaping @MainActor (Bool) -> Void
        ) -> Void

    struct Tab: Identifiable {
        let id = UUID()
        var title: String
        var holder: TerminalSessionHolder
    }

    private(set) var tabs: [Tab] = []
    var selected: UUID?
    var broadcast = false
    private let requestUserClose: UserCloseRequester

    init(
        requestUserClose: @escaping UserCloseRequester = { holder, completion in
            holder.requestUserClose(completion)
        }
    ) {
        self.requestUserClose = requestUserClose
    }

    func ensureFirstTab(named title: String) {
        guard tabs.isEmpty else { return }
        addTab(named: title)
    }

    @discardableResult
    func addTab(named title: String) -> Tab {
        let tab = Tab(title: title, holder: TerminalSessionHolder())
        tabs.append(tab)
        selected = tab.id
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let holder = tabs[index].holder
        requestUserClose(holder) { [weak self, weak holder] confirmed in
            guard confirmed, let self, let holder else { return }
            self.removeTab(id, holder: holder)
        }
    }

    private func removeTab(_ id: UUID, holder: TerminalSessionHolder) {
        guard let index = tabs.firstIndex(where: { $0.id == id && $0.holder === holder }) else {
            return
        }
        tabs.remove(at: index)
        if selected == id { selected = tabs.last?.id }
    }

    func selectNext(backwards: Bool) {
        guard let selected, let index = tabs.firstIndex(where: { $0.id == selected }),
            tabs.count > 1
        else { return }
        let next =
            backwards
            ? (index - 1 + tabs.count) % tabs.count : (index + 1) % tabs.count
        self.selected = tabs[next].id
    }

    @discardableResult
    func sendBroadcast(
        _ plan: MachineBroadcastPlan,
        isLive: @MainActor (TerminalSessionHolder) -> Bool = { $0.started },
        send: @MainActor (TerminalSessionHolder, String) -> Void = {
            $0.sendInput($1)
        }
    ) -> MachineTerminalBroadcastDelivery {
        var sent = 0
        var unavailable = 0
        for tab in tabs {
            guard isLive(tab.holder) else {
                unavailable += 1
                continue
            }
            send(tab.holder, plan.terminalInput)
            sent += 1
        }
        return MachineTerminalBroadcastDelivery(sent: sent, unavailable: unavailable)
    }

    func stopAll() {
        for tab in tabs { tab.holder.stop() }
        tabs = []
        selected = nil
    }
}

struct TerminalTabsView: View {
    let session: MachineSession
    var presented = true
    @State var model = TerminalTabsModel()
    @Environment(\.colorScheme) private var scheme
    @State private var command = ""
    @State private var broadcastError: String?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.3)
            ZStack {
                ForEach(model.tabs) { tab in
                    let active = presented && tab.id == model.selected
                    MachineTerminalTab(
                        session: session, active: active, holder: tab.holder
                    )
                    .opacity(tab.id == model.selected ? 1 : 0)
                    .allowsHitTesting(tab.id == model.selected)
                }
                if model.tabs.isEmpty {
                    Text("No terminals open.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            if model.broadcast { broadcastBar }
        }
        .onAppear {
            model.ensureFirstTab(named: "Shell 1")
            TerminalTabRegistry.register(model, machineID: session.machine.id)
        }
        .onDisappear {
            TerminalTabRegistry.unregister(model, machineID: session.machine.id)
        }
        .background(shortcuts)
    }

    private var shortcuts: some View {
        ZStack {
            Button("") { model.addTab(named: "Shell \(model.tabs.count + 1)") }
                .keyboardShortcut("t", modifiers: .command)
            Button("") {
                if let selected = model.selected { model.closeTab(selected) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var tabBar: some View {
        HStack(spacing: UIScale.pt(4)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(4)) {
                    ForEach(model.tabs) { tab in
                        Button {
                            model.selected = tab.id
                        } label: {
                            HStack(spacing: UIScale.pt(6)) {
                                Image(systemName: "terminal")
                                    .font(.system(size: UIScale.pt(9.5)))
                                Text(tab.title)
                                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                                if model.tabs.count > 1 {
                                    Button {
                                        model.closeTab(tab.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: UIScale.pt(7.5), weight: .bold))
                                    }
                                    .buttonStyle(.edith(.borderless))
                                }
                            }
                            .foregroundStyle(
                                tab.id == model.selected
                                    ? DashSkin.ink(dark) : DashSkin.inkFaint(dark)
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
                }
            }
            Button {
                model.addTab(named: "Shell \(model.tabs.count + 1)")
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.edith(.toolbar))
            .help("New terminal (⌘T)")

            Toggle("Broadcast", isOn: $model.broadcast)
                .toggleStyle(.checkbox)
                .font(.system(size: UIScale.pt(10.5)))
                .help("Type once, send to every tab")

            Button {
                TerminalWindow.open(session: session)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.edith(.toolbar))
            .help("Open terminals in their own window")
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(9))
        .background(.thinMaterial)
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
        let plan: MachineBroadcastPlan
        switch MachineBroadcastOperationExecution.plan(command: command) {
        case let .success(value):
            plan = value
        case let .failure(error):
            broadcastError = error.localizedDescription
            return
        }
        guard let delivery = TerminalTabRegistry.broadcast(plan, machineID: session.machine.id)
        else {
            broadcastError = "This machine has no open terminal tabs."
            return
        }
        guard delivery.isComplete else {
            broadcastError = TerminalTabRegistry.failureMessage(for: delivery)
            return
        }
        command = ""
        broadcastError = nil
    }
}

@MainActor
enum TerminalWindow {
    private struct Entry {
        let window: NSWindow
        let model: TerminalTabsModel
    }

    private static var windows: [UUID: Entry] = [:]

    static func open(session: MachineSession, model: TerminalTabsModel? = nil) {
        if let existing = windows[session.machine.id] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Terminal · \(session.machine.name)"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "EdithTerminal"
        let ownedModel = model ?? TerminalTabsModel()
        let hosting = NSHostingController(
            rootView: ZoomableRoot { TerminalTabsView(session: session, model: ownedModel) })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 900, height: 560))
        window.setFrameAutosaveName("EdithTerminalWindow")
        if window.frame.origin == .zero { window.center() }
        window.delegate = TerminalWindowDelegate.shared
        windows[session.machine.id] = Entry(window: window, model: ownedModel)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func forget(_ window: NSWindow) {
        guard let entry = windows.first(where: { $0.value.window === window }) else { return }
        entry.value.model.stopAll()
        window.contentViewController = nil
        window.contentView = nil
        windows.removeValue(forKey: entry.key)
    }
}

@MainActor
final class TerminalWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = TerminalWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        TerminalWindow.forget(window)
    }
}
