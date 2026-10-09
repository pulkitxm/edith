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
    @State private var workspace: CompanionWorkspaceSession
    private var home: CompanionHomeModel { workspace.home }
    private var chat: CompanionChatModel { workspace.chat }
    @StateObject private var fallbackOwner = WindowSessionOwner()
    @Environment(\.windowSessionOwner) private var sessionOwner
    private var capture: CompanionCaptureModel { sessionOwner?.capture ?? fallbackOwner.capture }
    private var library: CompanionLibraryModel { workspace.library }
    private var mind: CompanionMindModel { workspace.mind }
    private var desk: CompanionDeskModel { workspace.desk }
    private var backend: CompanionBackendModel { workspace.backend }
    private var reason: CompanionSettingsModel { workspace.settings }
    @AppStorage(AppStorageKeys.Companion.tab, store: SharedDefaults.store)
    private var tabRaw = CompanionTab.chat.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.windowVisible) private var windowVisible
    @State private var checkedSetup = false
    @State private var refreshTick = 0
    @State private var visited: Set<CompanionTab> = []
    @State private var setupModel: CompanionSetupModel?
    @AppStorage(AppStorageKeys.Companion.setupDeclined, store: SharedDefaults.store)
    private var setupDeclined = false

    init(session: CompanionWorkspaceSession? = nil) {
        _workspace = State(initialValue: session ?? CompanionWorkspaceSession())
    }

    private var dark: Bool { scheme == .dark }
    private var tab: CompanionTab { CompanionTab(rawValue: tabRaw) ?? .chat }
    private var tabBinding: Binding<CompanionTab> {
        Binding(get: { tab }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        @Bindable var library = workspace.library
        PageWorkspace {
            header
            tabBar
            Divider().opacity(0.35)
        } content: {
            screens.presenterCover(.memory)
        }
        .navigationRoute("tab", selection: tabBinding)
        .edithSheet(
            item: Binding(
                get: { setupModel },
                set: { model in
                    if model == nil { setupModel?.onFinish(false) } else { setupModel = model }
                }),
            dismissible: setupModel?.deploying != true
        ) { model in
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
        .onAppear { capture.setCaptureActive(tab == .capture && windowVisible) }
        .onChange(of: tab) { _, tab in
            capture.setCaptureActive(tab == .capture && windowVisible)
        }
        .onChange(of: windowVisible) { _, visible in
            capture.setCaptureActive(tab == .capture && visible)
        }
        .onDisappear { capture.setCaptureActive(false) }
        .pageRefresh(active: requestsEnabled, interval: { .seconds(20) }) {
            await home.refresh()
            guard !Task.isCancelled else { return }
            if !checkedSetup {
                checkedSetup = true
                if CompanionDeploymentStore.load() == nil, !home.reachable,
                    !setupDeclined
                {
                    openSetup()
                } else if !home.reachable {
                    select(.setup)
                }
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
                    .buttonStyle(.edith(.borderless))
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
                    .buttonStyle(.edith(.borderless))
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
        PageTabPicker(
            title: "Companion section",
            selection: Binding(get: { tab }, set: select),
            options: CompanionTab.allCases, label: { $0.title }
        )
        .pageGutter(compact)
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
                    .font(DashSkin.heading(20, weight: .semibold))
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
        let mounted = visited.union([tab])
        return ZStack {
            ForEach(CompanionTab.allCases) { item in
                if mounted.contains(item) {
                    screen(item)
                        .opacity(tab == item ? 1 : 0)
                        .allowsHitTesting(tab == item)
                        .accessibilityHidden(tab != item)
                }
            }
        }
        .onAppear { visited.insert(tab) }
    }

    @ViewBuilder
    private func screen(_ item: CompanionTab) -> some View {
        switch item {
        case .chat:
            CompanionChatScreen(
                model: chat, home: home, isActive: tab == .chat,
                openEpisode: { id in
                    select(.library)
                    Task { await library.select(id) }
                })
        case .capture:
            CompanionCaptureScreen(model: capture, home: home, isActive: tab == .capture)
        case .desk: CompanionDeskScreen(model: desk, isActive: tab == .desk)
        case .setup:
            CompanionBackendScreen(
                model: backend, isActive: tab == .setup, openSetup: { openSetup() })
        case .library:
            CompanionLibraryScreen(model: library, home: home, isActive: tab == .library)
        case .mind:
            CompanionMindScreen(
                model: mind, isActive: tab == .mind,
                openEpisode: { id in
                    select(.library)
                    Task { await library.select(id) }
                })
        case .settings:
            CompanionSettingsScreen(model: reason, home: home, isActive: tab == .settings)
        }
    }

    private func openSetup() {
        setupDeclined = false
        let model = CompanionSetupModel(onFinish: { finished in
            if !finished { setupDeclined = true }
            setupModel = nil
            refreshTick += 1
            Task { await home.refresh() }
        })
        model.begin(home: home, reasonerConfigured: reason.current?.configured == true)
        setupModel = model
    }

    private func select(_ item: CompanionTab) {
        visited.insert(item)
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
