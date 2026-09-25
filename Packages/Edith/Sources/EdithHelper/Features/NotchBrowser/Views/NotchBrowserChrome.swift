import AppKit
import EdithKit
import SwiftUI

struct NotchBrowserTabStrip<Leading: View>: View {
    var store: NotchBrowserStore
    @ViewBuilder var leading: Leading
    @State private var dragging: BrowserTab.ID?
    @State private var dragOffset: CGFloat = 0

    static var newTabWidth: CGFloat { 26 }
    static var spacing: CGFloat { 3 }

    static func tabWidth(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let room = available - newTabWidth - spacing * CGFloat(count)
        return min(210, max(38, (room / CGFloat(count)).rounded(.down)))
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(width: 1, height: 16)
            GeometryReader { geo in
                let width = Self.tabWidth(available: geo.size.width, count: store.tabs.count)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(store.tabs) { tab in
                            NotchBrowserTabItem(tab: tab, store: store, width: width)
                                .offset(x: dragging == tab.id ? dragOffset : 0)
                                .zIndex(dragging == tab.id ? 1 : 0)
                                .simultaneousGesture(reorder(tab, width: width))
                        }
                        newTabButton
                    }
                    .frame(height: geo.size.height)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private var newTabButton: some View {
        Button {
            store.newTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: Self.newTabWidth, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help("New tab")
    }

    private func reorder(_ tab: BrowserTab, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragging = tab.id
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let step = width + Self.spacing
                if let index = store.tabs.firstIndex(where: { $0.id == tab.id }), step > 0 {
                    let moved = Int((value.translation.width / step).rounded())
                    store.move(tab, to: index + moved)
                }
                dragging = nil
                dragOffset = 0
            }
    }
}

struct NotchBrowserTabItem: View {
    let tab: BrowserTab
    var store: NotchBrowserStore
    let width: CGFloat
    @State private var hovering = false

    private var selected: Bool { store.selectedTabID == tab.id }
    private var showsClose: Bool { width >= 64 && (selected || hovering) }

    var body: some View {
        Button {
            store.select(tab)
        } label: {
            HStack(spacing: 6) {
                NotchBrowserFavicon(tab: tab)
                if width >= 64 {
                    Text(tab.displayTitle)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, width >= 64 ? 9 : 0)
            .padding(.trailing, showsClose ? 24 : 8)
            .frame(width: width, height: 24, alignment: width >= 64 ? .leading : .center)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.edith(.borderless))
        .overlay(alignment: .trailing) {
            if showsClose {
                Button {
                    store.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 16, height: 16)
                        .background(.white.opacity(hovering ? 0.1 : 0), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.edith(.borderless))
                .padding(.trailing, 5)
                .help("Close tab")
            }
        }
        .onHover { hovering = $0 }
        .help(tab.displayTitle)
        .contextMenu { menu }
    }

    private var background: Color {
        if selected { return .white.opacity(0.17) }
        return hovering ? .white.opacity(0.08) : .clear
    }

    @ViewBuilder private var menu: some View {
        Button("New Tab") { store.newTab(after: tab) }
        Divider()
        Button("Reload") { tab.webView.reload() }
        Button("Duplicate") { store.duplicate(tab) }
        Button("Copy Link") { store.copyLink(tab) }
            .disabled(tab.url == nil)
        Button("Open in Chrome") { store.openInChrome(tab) }
            .disabled(tab.url == nil)
        Divider()
        Button("Close Tab") { store.close(tab) }
        Button("Close Other Tabs") { store.closeOthers(tab) }
            .disabled(store.tabs.count < 2)
        Button("Close Tabs to the Right") { store.closeToRight(tab) }
            .disabled(store.tabs.last?.id == tab.id)
        Divider()
        Button("Reopen Closed Tab") { store.reopenClosedTab() }
            .disabled(!store.canReopenClosedTab)
    }
}

struct NotchBrowserFavicon: View {
    let tab: BrowserTab

    var body: some View {
        Group {
            if let image = tab.favicon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if tab.isLoading {
                SkeletonReplica("Loading \(tab.displayTitle)") {
                    Circle().fill(.white.opacity(0.5))
                }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: 14, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct NotchBrowserToolbar: View {
    var store: NotchBrowserStore
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var tab: BrowserTab? { store.selectedTab }
    private var shownText: String { BrowserAddress.displayText(for: tab?.url) }

    var body: some View {
        HStack(spacing: 2) {
            control("chevron.left", help: "Back", enabled: tab?.canGoBack ?? false) {
                tab?.webView.goBack()
            }
            control("chevron.right", help: "Forward", enabled: tab?.canGoForward ?? false) {
                tab?.webView.goForward()
            }
            control(
                tab?.isLoading == true ? "xmark" : "arrow.clockwise",
                help: tab?.isLoading == true ? "Stop" : "Reload", enabled: tab != nil
            ) {
                guard let webView = tab?.webView else { return }
                if webView.isLoading { webView.stopLoading() } else { webView.reload() }
            }
            address
                .padding(.horizontal, 6)
            control("arrow.up.forward.app", help: "Open in Chrome", enabled: tab?.url != nil) {
                store.openInChrome(nil)
            }
            profileMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .overlay(alignment: .bottom) { progress }
        .onAppear { draft = shownText }
        .onChange(of: tab?.url) { if !editing { draft = shownText } }
        .onChange(of: store.selectedTabID) {
            editing = false
            draft = shownText
        }
        .onChange(of: store.addressFocusRequest) {
            draft = shownText
            editing = true
        }
        .onChange(of: editing) {
            guard editing else { return }
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var address: some View {
        HStack(spacing: 7) {
            Image(systemName: tab?.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            TextField("Search or enter address", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
                .focused($editing)
                .onSubmit {
                    store.submitAddress(draft)
                    editing = false
                }
                .onKeyPress(.escape) {
                    draft = shownText
                    editing = false
                    return .handled
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background(.white.opacity(editing ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(editing ? 0.25 : 0), lineWidth: 1)
        )
    }

    @ViewBuilder private var progress: some View {
        if let tab, tab.isLoading {
            ProgressView(value: max(0.08, tab.progress))
                .progressViewStyle(.linear)
                .tint(.white.opacity(0.75))
                .frame(height: 2)
                .scaleEffect(x: 1, y: 0.5, anchor: .bottom)
                .padding(.horizontal, 10)
        }
    }

    private var profileMenu: some View {
        Menu {
            if let profile = store.profile {
                Text(profile.email.map { "\(profile.name) (\($0))" } ?? profile.name)
                if let summary = store.syncSummary {
                    Text(summary)
                }
            }
            Divider()
            Button("Sync from Chrome Now") { store.syncNow() }
                .disabled(store.syncState.isBusy)
            Button("Switch Chrome Profile...") { store.chooseProfile() }
            Button("Reset Browser Size") { store.resetSize() }
            Divider()
            Button("Detach Profile and Clear Data", role: .destructive) { store.detach() }
        } label: {
            Group {
                if let profile = store.profile {
                    ChromeProfileAvatar(profile: profile, size: 20)
                } else {
                    Image(systemName: "person.crop.circle")
                }
            }
            .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.profile.map { "Chrome profile: \($0.name)" } ?? "Chrome profile")
    }

    private func control(
        _ icon: String, help: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.28))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .disabled(!enabled)
        .help(help)
    }
}
