import EdithCore
import EdithKit
import SwiftUI

struct GitHubPage: View {
    @State private var model = GitHubBrowserModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @FocusState private var addressFocused: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.55)
            toolbar
            if let error = model.addressError { issueStrip(error, color: DashSkin.danger) }
            if let error = model.resourceError, model.resource != nil {
                issueStrip(error.message, color: DashSkin.warn)
            }
            content
        }
        .background(DashSkin.paper(dark))
        .task { await model.start() }
    }

    private var tabBar: some View {
        HStack(spacing: UIScale.pt(7)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(5)) {
                    ForEach(model.session.tabs) { tab in tabControl(tab) }
                }
                .padding(.vertical, UIScale.pt(6))
            }
            Button("New Tab", systemImage: "plus", action: model.newTab)
                .labelStyle(.iconOnly)
                .keyboardShortcut("t", modifiers: .command)
                .buttonStyle(.edith(.toolbar))
                .help("New tab")
            Button(
                "Reopen Closed Tab", systemImage: "arrow.uturn.backward",
                action: model.reopenLastClosed
            )
            .labelStyle(.iconOnly)
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .buttonStyle(.edith(.toolbar))
            .disabled(model.session.recentlyClosed.isEmpty)
            .help("Reopen closed tab")
        }
        .padding(.horizontal, UIScale.pt(9))
        .frame(minHeight: UIScale.pt(42))
        .background(DashSkin.paper(dark))
    }

    private func tabControl(_ tab: GitHubBrowserTab) -> some View {
        let selected = model.session.selectedTabID == tab.id
        return HStack(spacing: UIScale.pt(6)) {
            Button {
                model.select(tab.id)
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: tab.isPinned ? "pin.fill" : "shippingbox")
                        .font(.system(size: UIScale.pt(10), weight: .medium))
                    Text(tab.title ?? routeTitle(tab.currentEntry.route))
                        .font(
                            .system(
                                size: UIScale.pt(11.5),
                                weight: selected ? .semibold : .regular)
                        )
                        .lineLimit(1)
                }
                .foregroundStyle(selected ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            if !tab.isPinned || selected {
                Button {
                    model.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: UIScale.pt(8.5), weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(17), height: UIScale.pt(17))
                }
                .buttonStyle(.edith(.toolbar))
                .help("Close tab")
            }
        }
        .padding(.horizontal, UIScale.pt(9))
        .frame(width: UIScale.pt(tab.isPinned ? 126 : 178), height: UIScale.pt(29))
        .background(
            selected ? DashSkin.paper2(dark) : Color.clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(8))
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(8))
                .strokeBorder(
                    selected ? DashSkin.lineStrong(dark) : Color.clear,
                    lineWidth: UIScale.pt(1))
        }
        .contextMenu {
            Button("Duplicate") { model.duplicate(tab.id) }
            Button(tab.isPinned ? "Unpin" : "Pin") { model.togglePinned(tab.id) }
            Divider()
            Button("Move Left") { model.move(tab.id, by: -1) }
            Button("Move Right") { model.move(tab.id, by: 1) }
            Divider()
            Button("Close", role: .destructive) { model.close(tab.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var toolbar: some View {
        HStack(spacing: UIScale.pt(8)) {
            toolbarButton("Back", symbol: "chevron.left", action: model.goBack)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.selectedTab?.canGoBack != true)
            toolbarButton("Forward", symbol: "chevron.right", action: model.goForward)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.selectedTab?.canGoForward != true)
            toolbarButton("Reload", symbol: "arrow.clockwise", action: model.reload)
                .keyboardShortcut("r", modifiers: .command)
            EdithTextField(
                placeholder: "GitHub URL or owner/repository",
                text: Binding(
                    get: { model.addressDraft }, set: { model.updateAddressDraft($0) }),
                icon: "lock.fill", compact: true, invalid: model.addressError != nil,
                focus: $addressFocused, onSubmit: model.submitAddress
            )
            .frame(minWidth: UIScale.pt(220), maxWidth: UIScale.pt(680))
            Button(action: model.submitAddress) {
                Label("Go", systemImage: "arrow.right")
            }
            .buttonStyle(.edith(.secondary))
            Spacer(minLength: 0)
            Button {
                if let route = model.currentRoute { openURL(route.url) }
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                    Image(systemName: "arrow.up.right.square")
                }
            }
            .buttonStyle(.edith(.toolbar))
            .disabled(model.currentRoute == nil)
            .help("Open the current URL on GitHub")
            Button {
                Task { await model.refreshReadiness() }
            } label: {
                if model.refreshingReadiness {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
            }
            .buttonStyle(.edith(.toolbar))
            .accessibilityLabel("Check GitHub authentication")
            .disabled(model.refreshingReadiness)
            .help("Check GitHub authentication")
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(8))
        .background(DashSkin.paper2(dark).opacity(dark ? 0.58 : 0.72))
    }

    private func toolbarButton(
        _ title: String, symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.edith(.toolbar))
            .help(title)
    }

    private func issueStrip(_ message: String, color: Color) -> some View {
        HStack(spacing: UIScale.pt(7)) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).lineLimit(2)
        }
        .font(.system(size: UIScale.pt(11.5), weight: .medium))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UIScale.pt(11))
        .padding(.vertical, UIScale.pt(7))
        .background(color.opacity(0.09))
    }

    @ViewBuilder private var content: some View {
        switch model.readiness {
        case .loading:
            initialSkeleton
        case .ready:
            supportedContent
        case let .degraded(detail):
            VStack(spacing: 0) {
                issueStrip(detail, color: DashSkin.warn)
                supportedContent
            }
        case let .needsSetup(detail):
            readinessState(
                "GitHub sign-in required", detail, "person.crop.circle.badge.exclamationmark")
        case let .uninstalled(detail):
            readinessState("GitHub CLI required", detail, "terminal")
        case let .failed(detail):
            readinessState("GitHub check failed", detail, "exclamationmark.triangle")
        case let .unsupported(detail):
            readinessState("GitHub is unavailable", detail, "nosign")
        case let .empty(detail):
            readinessState("No GitHub content", detail, "tray")
        }
    }

    @ViewBuilder private var supportedContent: some View {
        if let route = model.currentRoute {
            switch route.resource {
            case .repository, .content:
                resourceContent(route)
            case .home:
                routeState(
                    "Browse a repository", "Enter a GitHub URL or owner/repository above.",
                    "shippingbox")
            default:
                switch route.support {
                case .fullyNative, .nativeReadOnly:
                    routeState(
                        "Native view coming in a later slice",
                        "This route is classified and opens on GitHub until its native workflow ships.",
                        "arrow.up.right.square", openOnGitHub: true)
                case .opensOnGitHub:
                    routeState(
                        "Open this screen on GitHub",
                        "Sensitive repository settings remain on GitHub.", "lock.shield",
                        openOnGitHub: true)
                case .unavailable:
                    routeState(
                        "Unsupported GitHub route",
                        "Edith does not recognize this GitHub URL yet.", "questionmark.folder",
                        openOnGitHub: true)
                }
            }
        } else {
            routeState("GitHub", "Enter a repository URL to begin.", "shippingbox")
        }
    }

    private func resourceContent(_ route: GitHubRoute) -> some View {
        LoadingContainer(
            state: model.resourceState,
            title: model.resourceError?.title ?? "No GitHub content",
            message: model.resourceError?.message ?? "GitHub returned no content for this URL.",
            retry: model.retryResourceLoad
        ) {
            if let resource = model.resource {
                GitHubRepositoryResourceView(
                    resource: resource, route: route,
                    navigate: { destination, newTab in
                        model.navigate(to: destination, inNewTab: newTab)
                    }, openURL: { openURL($0) })
            }
        } placeholder: {
            initialSkeleton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readinessState(_ title: String, _ detail: String, _ symbol: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            Button("Check again") { Task { await model.refreshReadiness() } }
                .buttonStyle(.edith(.secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func routeState(
        _ title: String, _ detail: String, _ symbol: String, openOnGitHub: Bool = false
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            if openOnGitHub, let route = model.currentRoute {
                Button("Open on GitHub") { openURL(route.url) }
                    .buttonStyle(.edith(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var initialSkeleton: some View {
        GeometryReader { proxy in
            switch model.currentRoute?.resource {
            case let .content(_, kind, _, _, _):
                if kind == .tree {
                    directorySkeleton
                } else {
                    fileSkeleton
                }
            case .repository:
                repositorySkeleton(wide: proxy.size.width >= UIScale.pt(840))
            default:
                repositorySkeleton(wide: proxy.size.width >= UIScale.pt(840))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func repositorySkeleton(wide: Bool) -> some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: UIScale.pt(15)) {
                HStack(spacing: UIScale.pt(8)) {
                    SkeletonBlock(width: 18, height: 18, corner: 5)
                    SkeletonBlock(width: 210, height: 18)
                    SkeletonBlock(width: 46, height: 19, corner: 8)
                }
                SkeletonBlock(width: 390, height: 10)
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
                    VStack(spacing: 0) {
                        HStack {
                            SkeletonBlock(width: 116, height: 29, corner: 7)
                            Spacer()
                            SkeletonBlock(width: 78, height: 20, corner: 6)
                        }
                        .padding(UIScale.pt(11))
                        Divider().opacity(0.25)
                        HStack(spacing: UIScale.pt(8)) {
                            SkeletonBlock(width: 18, height: 18, corner: 9)
                            SkeletonBlock(width: 240, height: 10)
                            Spacer()
                            SkeletonBlock(width: 55, height: 9)
                        }
                        .padding(UIScale.pt(11))
                        Divider().opacity(0.25)
                        skeletonRows(12)
                    }
                    .background(
                        DashSkin.paper2(dark),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(11)))
                    if wide {
                        VStack(alignment: .leading, spacing: UIScale.pt(11)) {
                            SkeletonBlock(width: 62, height: 12)
                            SkeletonBlock(width: 198, height: 9)
                            SkeletonBlock(width: 176, height: 9)
                            Divider().opacity(0.25)
                            ForEach(0..<5, id: \.self) { _ in
                                SkeletonBlock(width: 128, height: 9)
                            }
                        }
                        .padding(UIScale.pt(14))
                        .frame(width: UIScale.pt(245), alignment: .leading)
                        .background(
                            DashSkin.paper2(dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(11)))
                    }
                }
            }
            .padding(UIScale.pt(wide ? 20 : 14))
            .frame(maxWidth: UIScale.pt(1_220), maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityLabel("Loading repository")
    }

    private var directorySkeleton: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                HStack(spacing: UIScale.pt(8)) {
                    SkeletonBlock(width: 110, height: 12)
                    SkeletonBlock(width: 10, height: 10)
                    SkeletonBlock(width: 86, height: 12)
                    Spacer()
                    SkeletonBlock(width: 92, height: 26, corner: 7)
                }
                .padding(UIScale.pt(14))
                Divider().opacity(0.3)
                skeletonRows(14)
                    .padding(UIScale.pt(18))
            }
        }
        .accessibilityLabel("Loading directory")
    }

    private var fileSkeleton: some View {
        SkeletonGroup {
            VStack(spacing: 0) {
                HStack(spacing: UIScale.pt(8)) {
                    SkeletonBlock(width: 230, height: 12)
                    Spacer()
                    SkeletonBlock(width: 70, height: 26, corner: 7)
                    SkeletonBlock(width: 82, height: 26, corner: 7)
                }
                .padding(UIScale.pt(14))
                Divider().opacity(0.3)
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { index in
                        HStack(spacing: 0) {
                            SkeletonBlock(width: 20, height: 8, corner: 3)
                                .frame(width: UIScale.pt(52), alignment: .trailing)
                                .padding(.trailing, UIScale.pt(10))
                            Divider().opacity(0.18)
                            Color.clear.frame(width: UIScale.pt(Double(index % 4) * 12 + 12))
                            SkeletonBlock(
                                width: [190, 310, 145, 380, 255][index % 5], height: 8,
                                corner: 3)
                            Spacer(minLength: 0)
                        }
                        .frame(height: UIScale.pt(22))
                    }
                }
                .padding(.vertical, UIScale.pt(10))
                .background(DashSkin.paper2(dark))
            }
        }
        .accessibilityLabel("Loading file")
    }

    private func skeletonRows(_ count: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: UIScale.pt(9)) {
                    SkeletonBlock(width: 15, height: 15, corner: 4)
                    SkeletonBlock(width: index.isMultiple(of: 4) ? 105 : 158, height: 9)
                    Spacer(minLength: UIScale.pt(12))
                    SkeletonBlock(width: 84, height: 8)
                }
                .padding(.horizontal, UIScale.pt(12))
                .frame(height: UIScale.pt(32))
                if index < count - 1 { Divider().opacity(0.16) }
            }
        }
    }

    private func routeTitle(_ route: GitHubRoute) -> String {
        switch route.resource {
        case let .repository(repository):
            repository.name
        case let .content(repository, _, revisionPath, _, _):
            revisionPath.last ?? repository.name
        default:
            "GitHub"
        }
    }
}
