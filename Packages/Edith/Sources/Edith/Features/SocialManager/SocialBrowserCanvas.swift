import AppKit
import EdithKit
import SwiftUI
import WebKit

struct SocialBrowserCanvas: View {
    let model: SocialManagerModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let gap = UIScale.pt(6)
            ZStack(alignment: .topLeading) {
                ForEach(model.catalog.accounts.filter { model.sessions[$0.id] != nil }) { account in
                    if let tab = model.tabs.first(where: {
                        $0.layout.contains(account.id.uuidString)
                    }),
                        let session = model.sessions[account.id]
                    {
                        let key = account.id.uuidString
                        let frames = tab.layout.paneFrames(in: rect, gap: gap)
                        let frame =
                            tab.zoomed == key
                            ? tab.layout.content(in: rect, gap: gap) : frames[key] ?? rect
                        let visible =
                            !model.showingAccounts && tab.id == model.selectedTabID
                            && (tab.zoomed == nil || tab.zoomed == key)
                        SocialBrowserPane(
                            model: model, account: account, session: session, tab: tab
                        )
                        .frame(width: max(0, frame.width), height: max(0, frame.height))
                        .offset(x: frame.minX, y: frame.minY)
                        .opacity(visible ? 1 : 0).allowsHitTesting(visible)
                        .accessibilityHidden(!visible).zIndex(visible ? 1 : 0)
                        .animation(model.layoutAnimation, value: frame)
                    }
                }
                if let tab = model.currentTab, tab.layout.paneCount > 1, tab.zoomed == nil {
                    ForEach(tab.layout.paneDividers(in: rect, gap: gap)) { divider in
                        HerdrLayoutDividerHandle(
                            axis: divider.axis, dark: scheme == .dark,
                            onDrag: { delta in
                                model.resize(
                                    split: divider.splitID, index: divider.index,
                                    change: Double(delta / divider.span))
                            }, onEqualize: { model.equalize() }
                        )
                        .frame(width: divider.rect.width, height: divider.rect.height)
                        .offset(x: divider.rect.minX, y: divider.rect.minY).zIndex(2)
                    }
                }
            }
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .clipped()
        }
    }
}

private struct SocialBrowserPane: View {
    let model: SocialManagerModel
    let account: SocialAccount
    let session: SocialBrowserSession
    let tab: SocialWorkspaceTab
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var key: String { account.id.uuidString }
    private var focused: Bool { tab.focused == key }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(6)) {
                Button {
                    model.focus(key)
                    model.activateFocusedBrowser()
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        SocialAvatar(
                            image: model.avatars[account.id], initials: account.initials,
                            name: account.name, size: 24)
                        Text(model.accountTitle(account)).font(
                            .edithText(.subheadline).weight(.semibold)
                        )
                        .lineLimit(1)
                        Text(model.platform(for: account)?.name ?? "").font(.edithText(.caption))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless)).help("Focus \(account.name)")
                Menu {
                    paneActions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Manage \(account.name) pane")
                if tab.layout.paneCount > 1 {
                    Button {
                        model.toggleZoom(key)
                    } label: {
                        Image(
                            systemName: tab.zoomed == key
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel(
                        tab.zoomed == key ? "Restore panes" : "Maximize \(account.name)")
                }
                Button {
                    model.closeAccount(key)
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close \(account.name)")
            }
            .padding(UIScale.pt(8))
            .background(focused ? DashSkin.accent(dark).opacity(0.1) : DashSkin.paper2(dark))
            .contextMenu { paneActions }
            .herdrDropFrame("paneHeader:" + key)
            .herdrDraggable(.pane(key), simultaneous: true)
            if session.pages.count > 1 {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(session.pages) { page in
                            Button(page.title) { session.selectedPageID = page.id }
                                .font(.edithText(.caption)).lineLimit(1)
                            Button {
                                session.closePage(page)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Close website tab \(page.title)")
                        }
                    }.padding(UIScale.pt(6))
                }
            }
            if let page = session.selectedPage {
                SocialBrowserContent(
                    model: model, account: account, page: page, website: session.website)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(7)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(7)).strokeBorder(
                focused ? DashSkin.accent(dark) : DashSkin.line(dark)
            ).allowsHitTesting(false))
    }

    @ViewBuilder private var paneActions: some View {
        Button("Focus pane") {
            model.select(tab); model.focus(key)
            model.activateFocusedBrowser()
        }
        if tab.layout.paneCount > 1 {
            Button(tab.zoomed == key ? "Restore panes" : "Maximize pane") {
                model.select(tab); model.toggleZoom(key)
            }
            Button("Move to its own tab") { model.openInNewTab(account) }
            Menu("Position beside") {
                ForEach(tab.layout.panes.filter { $0 != key }, id: \.self) { other in
                    if let target = model.account(other) {
                        Menu(model.accountTitle(target)) {
                            Button("On the right") {
                                model.moveToTab(account, tabID: tab.id, near: other)
                            }
                            Button("Below") {
                                model.moveToTab(account, tabID: tab.id, near: other, side: .bottom)
                            }
                        }
                    }
                }
            }
        }
        Button("Open in new window") { SocialWorkspaceWindow.open(key, from: model) }
        if let page = session.selectedPage {
            Menu("Website zoom") {
                Button("Zoom in") { page.webView.pageZoom = min(3, page.webView.pageZoom + 0.1) }
                Button("Zoom out") { page.webView.pageZoom = max(0.5, page.webView.pageZoom - 0.1) }
                Button("Actual size") { page.webView.pageZoom = 1 }
            }
            Button("New website tab") {
                session.makePage().webView.load(URLRequest(url: session.website))
            }
        }
        SocialAccountActions(model: model, account: account)
        Divider()
        Button("Close pane") { model.closeAccount(key) }
    }
}

struct SocialBrowserContent: View {
    let model: SocialManagerModel
    let account: SocialAccount
    let page: SocialBrowserPage
    let website: URL
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            navigation
            if page.isLoading {
                ProgressView(value: page.progress).progressViewStyle(.linear)
                    .frame(height: UIScale.pt(2)).accessibilityLabel("Website loading")
            }
            if let error = page.error {
                HStack {
                    Text(error).font(.edithText(.caption)).fixedSize(
                        horizontal: false, vertical: true)
                    Button("Reload") { page.retry() }
                }
                .padding(UIScale.pt(8))
            }
            SocialWebView(webView: page.webView).id(page.id)
        }
        .onAppear { address = (page.url ?? website).absoluteString }
        .onChange(of: page.url) { _, url in
            if !addressFocused { address = (url ?? website).absoluteString }
        }
        .onChange(of: model.addressFocusRequest) {
            guard model.focusedAccount?.id == account.id else { return }
            address = (page.url ?? website).absoluteString
            addressFocused = true
        }
    }

    private var navigation: some View {
        HStack(spacing: UIScale.pt(8)) {
            Button {
                page.webView.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!page.canGoBack).accessibilityLabel("Back")
            Button {
                page.webView.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!page.canGoForward).accessibilityLabel("Forward")
            Button {
                page.isLoading ? page.webView.stopLoading() : page.retry()
            } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
            }.accessibilityLabel(page.isLoading ? "Stop loading" : "Reload")
            Button {
                page.webView.load(URLRequest(url: website))
            } label: {
                Image(systemName: "house")
            }
            .accessibilityLabel("Platform home")
            TextField("Website address", text: $address)
                .font(.edithText(.caption)).textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit {
                    do {
                        let url = try SocialPlatform.websiteURL(address)
                        page.webView.load(URLRequest(url: url))
                        addressFocused = false
                        page.webView.window?.makeFirstResponder(page.webView)
                    } catch { page.error = error.localizedDescription }
                }
                .help(page.url?.absoluteString ?? website.absoluteString)
        }
        .padding(UIScale.pt(8))
    }
}

private struct SocialWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
