import AppKit
import EdithKit
import SwiftUI

enum DockerScreen: String, CaseIterable, Identifiable {
    case containers
    case images
    case volumes
    case networks
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .system: return "Disk usage"
        }
    }

    var icon: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .system: return "chart.pie"
        }
    }
}

enum DockerDetailTab: String, CaseIterable, Identifiable {
    case logs
    case inspect
    case stats
    case processes
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logs: return "Logs"
        case .inspect: return "Inspect"
        case .stats: return "Stats"
        case .processes: return "Processes"
        case .files: return "Files"
        }
    }
}

struct PrunePlan: Identifiable, Equatable {
    let kind: String

    var id: String { kind }

    var title: String {
        switch kind {
        case "images": return "Prune unused images?"
        case "volumes": return "Prune unused volumes?"
        case "networks": return "Prune unused networks?"
        default: return "Prune the build cache?"
        }
    }

    var detail: String {
        switch kind {
        case "images":
            return "Every image no container is using is deleted on the machine and has to be "
                + "pulled again."
        case "volumes":
            return "Every volume no container is using is deleted on the machine, along with the "
                + "data inside it. This cannot be undone."
        case "networks": return "Every network no container is attached to is deleted."
        default: return "The build cache is deleted, so the next build starts from scratch."
        }
    }
}

struct DockerConsoleView: View {
    let session: MachineSession
    @Environment(\.colorScheme) private var scheme
    @State private var screen = DockerScreen.containers
    @State private var query = ""
    @State private var selected: DockerContainer?
    @State private var busyIDs: Set<String> = []
    @State private var error: String?
    @State private var terminalFor: DockerContainer?
    @State private var pendingRemoval: DockerContainer?
    @State private var pendingPrune: PrunePlan?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Group {
            if session.docker.isAvailable {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: UIScale.pt(178))
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                DockerUnavailableView(session: session)
            }
        }
        .background(DashSkin.paper(dark))
        .sheet(item: $terminalFor) { container in
            ContainerTerminalSheet(session: session, container: container)
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "container")?",
            isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let container = pendingRemoval {
                    perform(DockerCommands.lifecycle("rm", id: container.id), on: container.id)
                    if selected?.id == container.id { selected = nil }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        }
        .confirmationDialog(
            pendingPrune?.title ?? "Prune?",
            isPresented: Binding(
                get: { pendingPrune != nil }, set: { if !$0 { pendingPrune = nil } }),
            titleVisibility: .visible
        ) {
            Button("Prune", role: .destructive) {
                if let plan = pendingPrune {
                    perform(DockerCommands.prune(plan.kind), on: "prune")
                }
                pendingPrune = nil
            }
            Button("Cancel", role: .cancel) { pendingPrune = nil }
        } message: {
            Text(pendingPrune?.detail ?? "")
        }
        .task {
            await session.refreshImagesAndVolumes()
        }
        .onAppear { session.beginDockerObservation() }
        .onDisappear { session.endDockerObservation() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(session.machine.name.uppercased())
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                .tracking(UIScale.pt(0.6))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .padding(.horizontal, UIScale.pt(12))
                .padding(.top, UIScale.pt(12))
                .padding(.bottom, UIScale.pt(6))
            ForEach(DockerScreen.allCases) { item in
                Button {
                    screen = item
                    selected = nil
                } label: {
                    HStack(spacing: UIScale.pt(8)) {
                        Image(systemName: item.icon)
                            .font(.system(size: UIScale.pt(11.5)))
                            .frame(width: UIScale.pt(16))
                        Text(item.title)
                            .font(.system(size: UIScale.pt(12.5)))
                        Spacer(minLength: 0)
                        if item == .containers, !session.containers.isEmpty {
                            Text("\(session.containers.filter { $0.state.isRunning }.count)")
                                .font(DashSkin.mono(10))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                    .foregroundStyle(
                        screen == item ? DashSkin.ink(dark) : DashSkin.inkSoft(dark)
                    )
                    .padding(.horizontal, UIScale.pt(10))
                    .padding(.vertical, UIScale.pt(6))
                    .background(
                        screen == item
                            ? DashSkin.accent(dark).opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.horizontal, UIScale.pt(6))
            }
            Spacer(minLength: 0)
            if let usage = session.diskUsage.first(where: { $0.type == "Images" }) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("IMAGES")
                        .font(.system(size: UIScale.pt(8.5), weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Text(ByteFormatter.string(usage.sizeBytes))
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                }
                .padding(UIScale.pt(12))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        if let container = selected {
            DockerContainerDetail(
                session: session, container: container, dark: dark,
                onBack: { selected = nil },
                onAction: { action in
                    perform(DockerCommands.lifecycle(action, id: container.id), on: container.id)
                },
                onShell: { terminalFor = container },
                onRemove: { pendingRemoval = container },
                onSwitch: { selected = $0 })
        } else {
            VStack(spacing: 0) {
                header
                if let error {
                    Text(error)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .padding(.horizontal, UIScale.pt(16))
                        .padding(.vertical, UIScale.pt(7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DashSkin.danger.opacity(0.12))
                }
                list
            }
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(10)) {
            Text(screen.title)
                .font(DashSkin.serif(20))
                .foregroundStyle(DashSkin.ink(dark))
            Spacer(minLength: 0)
            SearchField(placeholder: "Filter", text: $query)
                .frame(width: UIScale.pt(200))
            Button {
                session.refreshDockerNow()
                Task { await session.refreshImagesAndVolumes() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Refresh")
            Menu {
                Button("Prune unused images…") { pendingPrune = PrunePlan(kind: "images") }
                Button("Prune unused volumes…") { pendingPrune = PrunePlan(kind: "volumes") }
                Button("Prune networks…") { pendingPrune = PrunePlan(kind: "networks") }
                Button("Prune build cache…") { pendingPrune = PrunePlan(kind: "builder") }
            } label: {
                Image(systemName: "trash")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reclaim space")
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.vertical, UIScale.pt(12))
    }

    @ViewBuilder
    private var list: some View {
        switch screen {
        case .containers:
            DockerContainerList(
                session: session, query: query, dark: dark, busyIDs: busyIDs,
                onOpen: { selected = $0 },
                onAction: { container, action in
                    perform(
                        DockerCommands.lifecycle(action, id: container.id), on: container.id)
                },
                onShell: { terminalFor = $0 },
                onRemove: { pendingRemoval = $0 },
                onGroupAction: { key, containers, action in
                    guard !containers.isEmpty else { return }
                    let project = String(key.dropFirst(DockerContainerList.groupKeyPrefix.count))
                    perform(
                        DockerCommands.lifecycle(action, ids: containers.map(\.id)), on: key,
                        describing: "\(action == "start" ? "Start" : "Stop") failed for "
                            + (project.isEmpty ? "Standalone" : project))
                })
        case .images:
            DockerSimpleList(
                rows: imageRows, dark: dark,
                onDelete: { id in
                    perform(DockerCommands.removeImage(id, force: false), on: id)
                })
        case .volumes:
            DockerSimpleList(
                rows: volumeRows, dark: dark,
                onDelete: { name in perform(DockerCommands.removeVolume(name), on: name) })
        case .networks:
            DockerSimpleList(rows: networkRows, dark: dark, onDelete: nil)
        case .system:
            DockerUsageView(session: session, dark: dark)
        }
    }

    private var imageRows: [DockerRow] {
        session.images
            .filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
            .map {
                DockerRow(
                    id: $0.dangling ? $0.id : $0.displayName, title: $0.displayName,
                    subtitle: "\($0.shortID) · \($0.createdSince)",
                    trailing: ByteFormatter.string($0.sizeBytes), symbol: "square.stack.3d.up",
                    badge: $0.dangling ? "dangling" : nil)
            }
    }

    private var volumeRows: [DockerRow] {
        session.volumes
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map {
                DockerRow(
                    id: $0.name, title: $0.name, subtitle: $0.driver,
                    trailing: $0.sizeBytes.map { ByteFormatter.string($0) } ?? "—",
                    symbol: "externaldrive", badge: $0.inUse ? "in use" : nil)
            }
    }

    private var networkRows: [DockerRow] {
        session.networks
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map {
                DockerRow(
                    id: $0.id, title: $0.name, subtitle: $0.driver, trailing: $0.scope,
                    symbol: "network", badge: nil)
            }
    }

    private func perform(_ command: String, on id: String, describing: String? = nil) {
        busyIDs.insert(id)
        error = nil
        Task {
            let result = await session.runDocker(command)
            busyIDs.remove(id)
            if case let .failure(failure) = result {
                let detail = failure.localizedDescription
                error = describing.map { "\($0): \(detail)" } ?? detail
            }
            await session.refreshImagesAndVolumes()
        }
    }
}

struct DockerRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let trailing: String
    let symbol: String
    let badge: String?
}

struct DockerUnavailableView: View {
    let session: MachineSession
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(10)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(30)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(title)
                .font(DashSkin.serif(18))
                .foregroundStyle(DashSkin.ink(dark))
            Text(detail)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .multilineTextAlignment(.center)
                .frame(maxWidth: UIScale.pt(420))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch session.docker.status {
        case .missing: return "Docker is not installed on this machine."
        case .permissionDenied: return "This user cannot reach the Docker socket."
        case let .daemonDown(message): return message
        case .available, .unknown: return ""
        }
    }

    private var detail: String {
        switch session.docker.status {
        case .missing: return "Install Docker Engine there and this screen fills in."
        case .permissionDenied:
            return "Run sudo usermod -aG docker $USER on the machine, then log out and back in."
        case .daemonDown: return "Start the Docker service on the machine and refresh."
        case .available, .unknown: return ""
        }
    }

    private var symbol: String {
        switch session.docker.status {
        case .permissionDenied: return "lock"
        case .daemonDown: return "exclamationmark.triangle"
        default: return "shippingbox"
        }
    }
}

@MainActor
enum DockerWindow {
    private static var windows: [UUID: NSWindow] = [:]

    static func open(session: MachineSession) {
        if let existing = windows[session.machine.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Docker · \(session.machine.name)"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "EdithDocker"
        let hosting = NSHostingController(
            rootView: ZoomableRoot { DockerConsoleView(session: session) })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1020, height: 660))
        window.setFrameAutosaveName("EdithDockerWindow")
        if window.frame.origin == .zero { window.center() }
        window.delegate = DockerWindowDelegate.shared
        windows[session.machine.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func forget(_ window: NSWindow) {
        windows = windows.filter { $0.value !== window }
    }
}

@MainActor
final class DockerWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = DockerWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DockerWindow.forget(window)
    }
}
