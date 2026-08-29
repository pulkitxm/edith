import EdithCore
import EdithKit
import SwiftUI

struct GitHubPage: View {
    @State private var model = GitHubBrowserModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            toolbar
            if let error = model.addressError { issueStrip(error) }
            content
        }
        .task { await model.start() }
    }

    private var tabBar: some View {
        HStack(spacing: UIScale.pt(5)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIScale.pt(4)) {
                    ForEach(model.session.tabs) { tab in tabControl(tab) }
                }
            }
            Button("New Tab", systemImage: "plus", action: model.newTab)
                .labelStyle(.iconOnly)
                .keyboardShortcut("t", modifiers: .command)
            Button(
                "Reopen Closed Tab", systemImage: "arrow.uturn.backward",
                action: model.reopenLastClosed
            )
            .labelStyle(.iconOnly)
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model.session.recentlyClosed.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(UIScale.pt(8))
    }

    private func tabControl(_ tab: GitHubBrowserTab) -> some View {
        let selected = model.session.selectedTabID == tab.id
        return Button {
            model.select(tab.id)
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                if tab.isPinned { Image(systemName: "pin.fill") }
                Text(tab.title ?? "GitHub").lineLimit(1)
            }
            .foregroundStyle(selected ? .primary : .secondary)
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
    }

    private var toolbar: some View {
        HStack(spacing: UIScale.pt(7)) {
            Button("Back", systemImage: "chevron.left", action: model.goBack)
                .labelStyle(.iconOnly)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.selectedTab?.canGoBack != true)
            Button("Forward", systemImage: "chevron.right", action: model.goForward)
                .labelStyle(.iconOnly)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.selectedTab?.canGoForward != true)
            Button("Reload", systemImage: "arrow.clockwise", action: model.reload)
                .labelStyle(.iconOnly)
                .keyboardShortcut("r", modifiers: .command)
            TextField(
                "GitHub URL",
                text: Binding(
                    get: { model.addressDraft }, set: { model.updateAddressDraft($0) })
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(model.submitAddress)
            Button("Go", action: model.submitAddress)
            Button("Open on GitHub") {
                if let route = model.currentRoute { openURL(route.url) }
            }
            .disabled(model.currentRoute == nil)
            Button {
                Task { await model.refreshReadiness() }
            } label: {
                if model.refreshingReadiness {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
            }
            .accessibilityLabel("Check GitHub authentication")
            .disabled(model.refreshingReadiness)
        }
        .buttonStyle(.borderless)
        .padding(UIScale.pt(8))
    }

    private func issueStrip(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UIScale.pt(6))
    }

    @ViewBuilder private var content: some View {
        switch model.readiness {
        case .loading:
            initialSkeleton
        case let .ready(detail):
            supportedContent(detail)
        case let .degraded(detail):
            VStack(spacing: 0) {
                issueStrip(detail); supportedContent(detail)
            }
        case let .needsSetup(detail):
            state("GitHub sign-in required", detail, "person.crop.circle.badge.exclamationmark")
        case let .uninstalled(detail):
            state("GitHub CLI required", detail, "terminal")
        case let .failed(detail):
            state("GitHub check failed", detail, "exclamationmark.triangle")
        case let .unsupported(detail):
            state("GitHub is unavailable", detail, "nosign")
        case let .empty(detail):
            state("No GitHub content", detail, "tray")
        }
    }

    @ViewBuilder private func supportedContent(_ detail: String) -> some View {
        if let route = model.currentRoute {
            switch route.support {
            case .fullyNative:
                state(
                    "Native GitHub route", "Fully native: \(route.url.absoluteString)",
                    "chevron.left.forwardslash.chevron.right")
            case .nativeReadOnly:
                state(
                    "Read-only GitHub view", "Native read-only: \(route.url.absoluteString)",
                    "eye")
            case .opensOnGitHub:
                state("Open this page on GitHub", route.url.absoluteString, "safari")
            case .unavailable:
                state("Unsupported GitHub route", route.url.absoluteString, "questionmark.folder")
            }
        } else {
            state("GitHub", detail, "chevron.left.forwardslash.chevron.right")
        }
    }

    private func state(_ title: String, _ detail: String, _ symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }

    @ViewBuilder private var initialSkeleton: some View {
        VStack(spacing: UIScale.pt(12)) {
            switch model.currentRoute?.resource {
            case let .content(_, kind, _, _, _):
                GitHubBrowserFileHeaderSkeleton(dark: dark)
                if kind == .tree {
                    GitHubTreeSkeleton(dark: dark)
                } else {
                    GitHubCodeSkeleton(dark: dark)
                }
            case .repository, .branches, .tags:
                GitHubBrowserFileHeaderSkeleton(dark: dark)
                GitHubTreeSkeleton(dark: dark)
            case .commits, .commit, .comparison:
                GitHubCommitHistorySkeleton(dark: dark)
            default:
                GitHubRepositoryListSkeleton(dark: dark)
            }
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
