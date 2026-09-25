import AppKit
import WebKit

@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let webView: NotchWebView
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var favicon: NSImage?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(webView: NotchWebView) {
        self.webView = webView
        sync()
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.syncOnMain() },
            webView.observe(\.url) { [weak self] _, _ in self?.syncOnMain() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.syncOnMain() },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.syncOnMain() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.syncOnMain() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.syncOnMain() },
        ]
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host(), !host.isEmpty { return host }
        return "New Tab"
    }

    var origin: String? { url.flatMap(BrowserTab.origin(of:)) }

    nonisolated static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host()?.lowercased()
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port = url.port, port != defaultPort else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    func close() {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
    }

    nonisolated private func syncOnMain() {
        MainActor.assumeIsolated { sync() }
    }

    private func sync() {
        let nextTitle = webView.title ?? ""
        if title != nextTitle { title = nextTitle }
        if url != webView.url { url = webView.url }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if progress != webView.estimatedProgress { progress = webView.estimatedProgress }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }
}

@MainActor
final class NotchWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var needsPanelToBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        NotchWebMenu.retitle(menu)
    }
}

enum NotchWebMenu {
    static let newTabTitles: [String: String] = [
        "WKMenuItemIdentifierOpenLinkInNewWindow": "Open Link in New Tab",
        "WKMenuItemIdentifierOpenImageInNewWindow": "Open Image in New Tab",
        "WKMenuItemIdentifierOpenFrameInNewWindow": "Open Frame in New Tab",
        "WKMenuItemIdentifierOpenMediaInNewWindow": "Open Video in New Tab",
    ]

    static func retitle(_ menu: NSMenu) {
        for item in menu.items {
            guard let identifier = item.identifier?.rawValue, let title = newTabTitles[identifier]
            else { continue }
            item.title = title
        }
    }
}
