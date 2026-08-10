import AppKit
import EdithKit
import Observation
import SwiftTerm
import SwiftUI

@MainActor
@Observable
final class TerminalTabsModel {
    struct Tab: Identifiable {
        let id = UUID()
        var title: String
        var holder: TerminalSessionHolder
    }

    private(set) var tabs: [Tab] = []
    var selected: UUID?
    var broadcast = false

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
        tabs[index].holder.stop()
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

    func send(_ text: String) {
        let targets = broadcast ? tabs : tabs.filter { $0.id == selected }
        for tab in targets {
            tab.holder.terminalView.send(txt: text)
        }
    }

    func stopAll() {
        for tab in tabs { tab.holder.stop() }
        tabs = []
        selected = nil
    }
}

struct TerminalTabsView: View {
    let session: MachineSession
    @State private var model = TerminalTabsModel()
    @Environment(\.colorScheme) private var scheme
    @State private var command = ""

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.3)
            ZStack {
                ForEach(model.tabs) { tab in
                    MachineTerminalTab(session: session, holder: tab.holder)
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
            TerminalTabRegistry.active = model
        }
        .onDisappear {
            if TerminalTabRegistry.active === model { TerminalTabRegistry.active = nil }
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
                                    .buttonStyle(.plain)
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
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
            Button {
                model.addTab(named: "Shell \(model.tabs.count + 1)")
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(HoverButtonStyle())
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
            .buttonStyle(HoverButtonStyle())
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
                .onSubmit {
                    model.send(command + "\n")
                    command = ""
                }
            Button("Send") {
                model.send(command + "\n")
                command = ""
            }
            .pointerCursor()
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(7))
        .background(DashSkin.warn.opacity(0.1))
    }
}

@MainActor
enum TerminalWindow {
    private static var windows: [UUID: NSWindow] = [:]

    static func open(session: MachineSession) {
        if let existing = windows[session.machine.id] {
            existing.makeKeyAndOrderFront(nil)
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
        let hosting = NSHostingController(
            rootView: ZoomableRoot { TerminalTabsView(session: session) })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 900, height: 560))
        window.setFrameAutosaveName("EdithTerminalWindow")
        if window.frame.origin == .zero { window.center() }
        window.delegate = TerminalWindowDelegate.shared
        windows[session.machine.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func forget(_ window: NSWindow) {
        windows = windows.filter { $0.value !== window }
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
