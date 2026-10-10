import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MachineDetailView: View {
    let session: MachineSession
    let model: MachinesModel
    @Binding var tab: MachineTab
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var visited: Set<MachineTab> = []
    @Environment(\.machineViewPresented) private var presented

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            tabBar
            Divider().opacity(0.35)
            detail
                .padding(.top, UIScale.pt(6))
        }
        .navigationRoute("tab", selection: $tab, isValid: tabIsAvailable)
        .machineActivity(session)
    }

    private func tabIsAvailable(_ tab: MachineTab) -> Bool {
        MachineTab.tabs(isLocal: session.isLocal, hasDocker: session.docker.isInstalled).contains(
            tab)
    }

    private var tabBar: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            MachinePageTabStrip(selection: tab) {
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
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, UIScale.pt(11))
                            .padding(.vertical, UIScale.pt(6))
                            .foregroundStyle(
                                tab == item ? DashSkin.ink(dark) : DashSkin.inkFaint(dark)
                            )
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
                        .buttonStyle(.edith(.borderless))
                        .help("\(item.title) (⌘-click to open it in its own window)")
                        .id(item)
                    }
                }
            }
            HStack(spacing: UIScale.pt(8)) {
                Spacer(minLength: 0)
                ConnectionPill(session: session, dark: dark)
                MachineControlCenterButton(session: session, dark: dark)
                    .id(session.id)
                if !session.isLocal {
                    MachinePowerControls(session: session, model: model, dark: dark)
                }
            }
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.bottom, UIScale.pt(12))
    }

    private func detach(_ item: MachineTab) {
        switch item {
        case .docker: DockerWindow.open(session: session)
        case .terminal: TerminalWindow.open(session: session)
        case .files: FinderWindow.open(session: session)
        default: MachineWindow.open(machineID: session.id, title: session.machine.name)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let mounted = visited.union([tab])
        ZStack {
            ForEach(MachineTab.tabs(isLocal: session.isLocal, hasDocker: true)) { item in
                if mounted.contains(item) {
                    screen(item, presented: item == tab)
                        .environment(\.machineViewPresented, item == tab && presented)
                        .opacity(item == tab ? 1 : 0)
                        .allowsHitTesting(item == tab)
                        .accessibilityHidden(item != tab)
                }
            }
        }
        .id(session.id)
        .onAppear { visited.insert(tab) }
        .onChange(of: tab) { _, opened in visited.insert(opened) }
        .onChange(of: session.id) { _, _ in visited = [tab] }
    }

    @ViewBuilder
    private func screen(_ item: MachineTab, presented: Bool) -> some View {
        switch item {
        case .overview: MachineOverviewTab(session: session, model: model)
        case .processes: MachineProcessesTab(session: session)
        case .docker: DockerConsoleView(session: session)
        case .terminal: TerminalTabsView(session: session, presented: presented)
        case .files: FinderWindowView(session: session)
        case .tools: MachineToolsTab(session: session, model: model)
        }
    }
}

struct ConnectionPill: View {
    let session: MachineSession
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            if session.state.isBusy {
                SkeletonGroup {
                    HStack(spacing: UIScale.pt(6)) {
                        SkeletonBlock(width: 7, height: 7, corner: 3.5)
                        SkeletonBlock(width: 74, height: 9, corner: 2)
                    }
                }
                .accessibilityLabel(MachineStatusStyle.detail(session.state))
            } else {
                Circle()
                    .fill(MachineStatusStyle.color(session.state, dark: dark))
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                Text(MachineStatusStyle.label(session.state))
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(MachineStatusStyle.detail(session.state))
            }
            if session.state.isRetryable {
                Button("Retry") { session.retry() }
                    .buttonStyle(.edith(.borderless))
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.accent(dark))
            }
        }
    }
}

struct MachineWindowView: View {
    let machineID: UUID
    @State private var router = WindowRouter()
    @State private var model = MachinesModel.shared
    @State private var tab = MachineTab.overview
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        let session = model.session(for: machineID)
        NavigationRouteHost(router: router) {
            GeometryReader { geometry in
                VStack(spacing: UIScale.pt(0)) {
                    PageHeader(
                        session.machine.name,
                        trailing: {
                            Text(model.isLocal(machineID) ? "Local" : session.machine.subtitle)
                                .font(DashSkin.mono(11))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .presenterBlur(MachinePrivacy.shared.hidesMachines)
                        }
                    )
                    .presenterBlur(MachinePrivacy.shared.hidesMachines)
                    MachineDetailView(session: session, model: model, tab: $tab)
                        .machinePrivacyCover()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DashSkin.paper(dark))
                .navigationRoute("machine", selection: .constant(machineID.uuidString))
                .navigationRoute("section", selection: .constant("machines"))
                .onAppear {
                    if case .disconnected = session.state { session.start() }
                }
            }
        }
    }
}

@MainActor
enum MachineWindow {
    static func open(machineID: UUID, title: String) {
        guard let client = MachinesModel.shared.uiClient else {
            MachinesModel.shared.operationError = "The owning app window bridge is unavailable."
            return
        }
        client.enqueue { try await client.openWindow(.init(kind: .machine, machineID: machineID)) }
    }
}
