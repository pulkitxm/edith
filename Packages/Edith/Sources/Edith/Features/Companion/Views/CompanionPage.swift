import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

private struct CompanionRequestsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct CompanionGenerationKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var companionRequestsEnabled: Bool {
        get { self[CompanionRequestsEnabledKey.self] }
        set { self[CompanionRequestsEnabledKey.self] = newValue }
    }

    var companionGeneration: Int {
        get { self[CompanionGenerationKey.self] }
        set { self[CompanionGenerationKey.self] = newValue }
    }
}

enum CompanionTab: String, CaseIterable, Identifiable {
    case chat
    case capture
    case desk
    case library
    case mind
    case setup
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .capture: return "Capture"
        case .desk: return "Desk"
        case .library: return "Library"
        case .mind: return "Mind"
        case .setup: return "Backend"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .capture: return "mic"
        case .desk: return "tray.full"
        case .library: return "books.vertical"
        case .mind: return "brain"
        case .setup: return "server.rack"
        case .settings: return "gearshape"
        }
    }
}

struct CompanionPage: View {
    @State private var home = CompanionHomeModel()
    @State private var chat = CompanionChatModel()
    @State private var capture = CompanionCaptureModel()
    @State private var library = CompanionLibraryModel()
    @State private var mind = CompanionMindModel()
    @State private var desk = CompanionDeskModel()
    @State private var backend = CompanionBackendModel()
    @State private var reason = CompanionSettingsModel()
    @AppStorage(AppStorageKeys.Companion.tab, store: SharedDefaults.store)
    private var tabRaw = CompanionTab.chat.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Namespace private var tabGlow
    @State private var refreshTick = 0
    @State private var setupModel: CompanionSetupModel?

    private var dark: Bool { scheme == .dark }
    private var tab: CompanionTab { CompanionTab(rawValue: tabRaw) ?? .chat }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            header
            tabBar
            Divider().opacity(0.35)
            screens
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pageBackground)
        .sheet(item: $setupModel) { model in
            CompanionSetupSheet(model: model, home: home)
        }
        .onDrop(of: [.fileURL], isTargeted: $library.dropTargeted) { providers in
            Task {
                let urls = await CompanionDrop.urls(from: providers)
                guard !urls.isEmpty else { return }
                select(.library)
                await library.ingest(urls: urls)
                await home.refresh()
            }
            return true
        }
        .task {
            guard requestsEnabled else { return }
            var first = true
            var lastTunnelAttempt = Date.distantPast
            while !Task.isCancelled {
                await home.refresh()
                if !home.reachable, let deployment = CompanionDeploymentStore.load(),
                    deployment.machineID != nil,
                    Date().timeIntervalSince(lastTunnelAttempt) > 60
                {
                    lastTunnelAttempt = Date()
                    if await CompanionTunnel.ensure(deployment) {
                        await home.refresh()
                    }
                }
                if first {
                    first = false
                    if CompanionDeploymentStore.load() == nil, !home.reachable {
                        openSetup()
                    } else if !home.reachable {
                        select(.setup)
                    }
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private var pageBackground: some View {
        DashSkin.paper(dark)
            .overlay(alignment: .topTrailing) {
                RadialGradient(
                    colors: [DashSkin.accent(dark).opacity(0.08), .clear], center: .topTrailing,
                    startRadius: 0, endRadius: 620
                )
                .ignoresSafeArea(edges: .vertical)
            }
            .ignoresSafeArea(edges: .vertical)
    }

    private var header: some View {
        PageHeader(
            "Companion",
            trailing: {
                HStack(spacing: UIScale.pt(10)) {
                    Button {
                        refreshTick += 1
                        Task { await home.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: UIScale.pt(11.5), weight: .medium))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Refresh this screen")
                    Button {
                        select(.setup)
                    } label: {
                        HStack(spacing: UIScale.pt(6)) {
                            Circle()
                                .fill(healthTint)
                                .frame(width: UIScale.pt(8), height: UIScale.pt(8))
                            Text(home.state.label)
                                .font(.system(size: UIScale.pt(11.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(healthHelp)
                }
            },
            accessory: {
                if let status = home.status {
                    Text(
                        "\(status.episodes) episodes, \(status.chunks) chunks indexed, "
                            + "\(status.observations) observations"
                    )
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        )
        .pageGutter(compact)
    }

    private var healthTint: Color {
        switch home.state {
        case .unreachable: DashSkin.inkFaint(dark)
        case .blocked: DashSkin.warn
        case .degraded: DashSkin.gold
        case .ready: DashSkin.ok
        }
    }

    private var healthHelp: String {
        guard home.reachable else {
            return "The companion backend is not reachable. Open Backend to choose where it runs."
        }
        let failing = home.failing
        guard !failing.isEmpty else {
            return home.checks.map { "\($0.name): \($0.detail)" }.joined(separator: "\n")
        }
        return failing.map { "\($0.name) (\($0.severityKind.rawValue)): \($0.detail)" }
            .joined(separator: "\n")
    }

    private var tabBar: some View {
        HStack(spacing: UIScale.pt(4)) {
            ForEach(CompanionTab.allCases) { item in
                Button {
                    select(item)
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
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: UIScale.pt(8))
                                .fill(DashSkin.paper2(dark))
                                .overlay {
                                    RoundedRectangle(cornerRadius: UIScale.pt(8))
                                        .strokeBorder(DashSkin.line(dark))
                                }
                                .matchedGeometryEffect(id: "companionTab", in: tabGlow)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(item.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.bottom, UIScale.pt(12))
    }

    private var screens: some View {
        ZStack {
            screenStack
            if library.dropTargeted {
                dropOverlay
            }
        }
        .environment(\.companionGeneration, home.generation &+ refreshTick)
        .animation(
            Motion.animation(Motion.snap, reduceMotion: reduceMotion),
            value: library.dropTargeted)
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .fill(DashSkin.paper(dark).opacity(0.88))
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .strokeBorder(
                    DashSkin.accent(dark), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            VStack(spacing: UIScale.pt(8)) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: UIScale.pt(26)))
                    .foregroundStyle(DashSkin.accent(dark))
                Text("Drop to remember")
                    .font(DashSkin.serif(20, weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("Notes, recordings, photos, video, PDFs")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
        .padding(UIScale.pt(10))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var screenStack: some View {
        ZStack {
            screen(.chat)
                .opacity(tab == .chat ? 1 : 0)
                .allowsHitTesting(tab == .chat)
                .accessibilityHidden(tab != .chat)
            screen(.capture)
                .opacity(tab == .capture ? 1 : 0)
                .allowsHitTesting(tab == .capture)
                .accessibilityHidden(tab != .capture)
            screen(.desk)
                .opacity(tab == .desk ? 1 : 0)
                .allowsHitTesting(tab == .desk)
                .accessibilityHidden(tab != .desk)
            screen(.setup)
                .opacity(tab == .setup ? 1 : 0)
                .allowsHitTesting(tab == .setup)
                .accessibilityHidden(tab != .setup)
            screen(.library)
                .opacity(tab == .library ? 1 : 0)
                .allowsHitTesting(tab == .library)
                .accessibilityHidden(tab != .library)
            screen(.mind)
                .opacity(tab == .mind ? 1 : 0)
                .allowsHitTesting(tab == .mind)
                .accessibilityHidden(tab != .mind)
            screen(.settings)
                .opacity(tab == .settings ? 1 : 0)
                .allowsHitTesting(tab == .settings)
                .accessibilityHidden(tab != .settings)
        }
    }

    @ViewBuilder
    private func screen(_ item: CompanionTab) -> some View {
        switch item {
        case .chat:
            CompanionChatScreen(
                model: chat, home: home,
                openEpisode: { id in
                    select(.library)
                    Task { await library.select(id) }
                })
        case .capture: CompanionCaptureScreen(model: capture, home: home)
        case .desk: CompanionDeskScreen(model: desk)
        case .setup:
            CompanionBackendScreen(model: backend, openSetup: { openSetup() })
        case .library: CompanionLibraryScreen(model: library, home: home)
        case .mind:
            CompanionMindScreen(
                model: mind,
                openEpisode: { id in
                    select(.library)
                    Task { await library.select(id) }
                })
        case .settings: CompanionSettingsScreen(model: reason, home: home)
        }
    }

    private func openSetup() {
        let model = CompanionSetupModel(onFinish: {
            setupModel = nil
            refreshTick += 1
            Task { await home.refresh() }
        })
        model.begin(home: home, reasonerConfigured: reason.current?.configured == true)
        setupModel = model
    }

    private func select(_ item: CompanionTab) {
        if item.rawValue != tabRaw { refreshTick += 1 }
        withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
            tabRaw = item.rawValue
        }
    }
}

enum CompanionDrop {
    @MainActor
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier) as? URL
            {
                urls.append(url)
            } else if let data = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil)
            {
                urls.append(url)
            }
        }
        return urls
    }
}
