import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

private struct CompanionRequestsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var companionRequestsEnabled: Bool {
        get { self[CompanionRequestsEnabledKey.self] }
        set { self[CompanionRequestsEnabledKey.self] = newValue }
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
        case .setup: return "Setup"
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

@MainActor
final class CompanionHomeModel: ObservableObject {
    @Published private(set) var checks: [CompanionCheck] = []
    @Published private(set) var status: CompanionStatus?
    @Published private(set) var error: String?

    var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    var healthy: Bool { !checks.isEmpty && checks.allSatisfy(\.ok) }

    func refresh() async {
        do {
            let client = client
            checks = try await client.health().checks
            status = try await client.status()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CompanionPage: View {
    @StateObject private var home = CompanionHomeModel()
    @StateObject private var chat = CompanionChatModel()
    @StateObject private var capture = CompanionCaptureModel()
    @StateObject private var library = CompanionLibraryModel()
    @StateObject private var mind = CompanionMindModel()
    @StateObject private var desk = CompanionDeskModel()
    @StateObject private var setup = CompanionSetupModel()
    @StateObject private var reason = CompanionSettingsModel()
    @AppStorage("companionTab", store: SharedDefaults.store)
    private var tabRaw = CompanionTab.chat.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Namespace private var tabGlow

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
        .background(DashSkin.paper(dark))
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
            while !Task.isCancelled {
                await home.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private var header: some View {
        PageHeader(
            "Companion",
            trailing: {
                HStack(spacing: UIScale.pt(6)) {
                    Circle()
                        .fill(home.healthy ? Color.green : Color.orange)
                        .frame(width: UIScale.pt(8), height: UIScale.pt(8))
                    Text(home.healthy ? "healthy" : "degraded")
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .help(home.checks.map { "\($0.name): \($0.detail)" }.joined(separator: "\n"))
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
                    .font(DashSkin.serif(UIScale.pt(20), weight: .semibold))
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
        case .setup: CompanionSetupScreen(model: setup)
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

    private func select(_ item: CompanionTab) {
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
