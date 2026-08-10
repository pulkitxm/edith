import AppKit
import EdithKit
import SwiftUI

struct MachineDetailView: View {
    @ObservedObject var session: MachineSession
    @ObservedObject var model: MachinesModel
    @Binding var tab: MachineTab
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            tabBar
            Divider().opacity(0.35)
            detail
                .padding(.top, UIScale.pt(6))
        }
    }

    private var tabBar: some View {
        HStack(spacing: UIScale.pt(4)) {
            let items = MachineTab.tabs(
                isLocal: session.isLocal, hasDocker: session.docker.isInstalled)
            ForEach(items) { item in
                Button {
                    if NSEvent.modifierFlags.contains(.command) {
                        detach(item)
                    } else {
                        tab = item
                    }
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Image(systemName: item.icon)
                            .font(.system(size: UIScale.pt(11), weight: .medium))
                        Text(item.title)
                            .font(.system(size: UIScale.pt(12.5), weight: .medium))
                    }
                    .padding(.horizontal, UIScale.pt(11))
                    .padding(.vertical, UIScale.pt(6))
                    .foregroundStyle(tab == item ? DashSkin.ink(dark) : DashSkin.inkFaint(dark))
                    .background(
                        tab == item ? DashSkin.paper2(dark) : .clear,
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                    )
                    .overlay {
                        if tab == item {
                            RoundedRectangle(cornerRadius: UIScale.pt(8))
                                .strokeBorder(DashSkin.line(dark))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("\(item.title) (⌘-click to open it in its own window)")
            }
            Button {
                FinderWindow.open(session: session)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: "folder")
                        .font(.system(size: UIScale.pt(11), weight: .medium))
                    Text("Files")
                        .font(.system(size: UIScale.pt(12.5), weight: .medium))
                }
                .padding(.horizontal, UIScale.pt(11))
                .padding(.vertical, UIScale.pt(6))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Browse files in their own window")

            Spacer(minLength: 0)
            ConnectionPill(session: session, dark: dark)
            if !session.isLocal {
                MachinePowerControls(session: session, model: model, dark: dark)
            }
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.bottom, UIScale.pt(12))
    }

    private func detach(_ item: MachineTab) {
        switch item {
        case .docker: DockerWindow.open(session: session)
        case .terminal: TerminalWindow.open(session: session)
        default: MachineWindow.open(machineID: session.id, title: session.machine.name)
        }
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            ForEach(MachineTab.tabs(isLocal: session.isLocal, hasDocker: true)) { item in
                screen(item)
                    .opacity(item == tab ? 1 : 0)
                    .allowsHitTesting(item == tab)
                    .accessibilityHidden(item != tab)
            }
        }
        .id(session.id)
    }

    @ViewBuilder
    private func screen(_ item: MachineTab) -> some View {
        switch item {
        case .overview: MachineOverviewTab(session: session)
        case .processes: MachineProcessesTab(session: session)
        case .docker: DockerConsoleView(session: session)
        case .terminal: TerminalTabsView(session: session)
        case .tools: MachineToolsTab(session: session, model: model)
        }
    }
}

struct ConnectionPill: View {
    @ObservedObject var session: MachineSession
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            if session.state.isBusy {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Circle()
                    .fill(MachineStatusStyle.color(session.state, dark: dark))
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
            }
            Text(MachineStatusStyle.label(session.state))
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
                .truncationMode(.tail)
            if session.state.isRetryable {
                Button("Retry") { session.retry() }
                    .buttonStyle(.plain)
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.accent(dark))
                    .pointerCursor()
            }
        }
    }
}

struct MachineWindowView: View {
    let machineID: UUID
    @StateObject private var model = MachinesModel.shared
    @State private var tab = MachineTab.overview
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let session = model.session(for: machineID)
        VStack(spacing: UIScale.pt(0)) {
            PageHeader(
                session.machine.name,
                trailing: {
                    Text(model.isLocal(machineID) ? "Local" : session.machine.subtitle)
                        .font(DashSkin.mono(11))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                })
            MachineDetailView(session: session, model: model, tab: $tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .onAppear {
            if case .disconnected = session.state { session.start() }
        }
    }
}

@MainActor
enum MachineWindow {
    private static var windows: [UUID: NSWindow] = [:]

    static func open(machineID: UUID, title: String) {
        if let existing = windows[machineID] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 440)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "EdithMachine"
        let hosting = NSHostingController(
            rootView: ZoomableRoot { MachineWindowView(machineID: machineID) })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 900, height: 620))
        window.setFrameAutosaveName("EdithMachine.\(machineID.uuidString)")
        if window.frame.origin == .zero { window.center() }
        window.delegate = MachineWindowDelegate.shared
        windows[machineID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func forget(_ window: NSWindow) {
        guard let key = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: key)
    }

    static func close(machineID: UUID) {
        windows[machineID]?.close()
        windows.removeValue(forKey: machineID)
    }

    static var openCount: Int { windows.count }
}

@MainActor
final class MachineWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MachineWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        MachineWindow.forget(window)
    }
}
