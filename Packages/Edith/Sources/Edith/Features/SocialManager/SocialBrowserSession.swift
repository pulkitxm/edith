import AppKit
import EdithKit
import Observation
import UniformTypeIdentifiers
import WebKit

@MainActor @Observable
final class SocialBrowserSession {
    let accountID: UUID
    private(set) var website: URL
    private(set) var pages: [SocialBrowserPage] = []
    var selectedPageID: UUID?
    var selectedPage: SocialBrowserPage? { pages.first { $0.id == selectedPageID } }
    @ObservationIgnored var onFocus: (() -> Void)?
    @ObservationIgnored let dataStore: WKWebsiteDataStore

    init(accountID: UUID, website: URL, dataStore: WKWebsiteDataStore) {
        self.accountID = accountID
        self.website = website
        self.dataStore = dataStore
        let page = makePage()
        page.webView.load(URLRequest(url: website))
    }

    @discardableResult
    func makePage(configuration supplied: WKWebViewConfiguration? = nil) -> SocialBrowserPage {
        let configuration = supplied ?? WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        let safari =
            Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "26.0"
        configuration.applicationNameForUserAgent = "Version/\(safari) Safari/605.1.15"
        let page = SocialBrowserPage(configuration: configuration)
        page.webView.onFocus = { [weak self] in self?.onFocus?() }
        page.onPopup = { [weak self] configuration in
            self?.makePage(configuration: configuration).webView
        }
        page.onOpenInBackground = { [weak self] url in self?.openInBackground(url) }
        page.onClose = { [weak self, weak page] in
            guard let page else { return }
            self?.closePage(page)
        }
        pages.append(page)
        selectedPageID = page.id
        return page
    }

    func openInBackground(_ url: URL) {
        let selected = selectedPageID
        makePage().webView.load(URLRequest(url: url))
        selectedPageID = selected
    }

    func closePage(_ page: SocialBrowserPage) {
        guard pages.count > 1 else { return }
        page.shutdown()
        pages.removeAll { $0.id == page.id }
        if selectedPageID == page.id { selectedPageID = pages.last?.id }
    }

    func updateWebsite(_ website: URL) {
        guard self.website != website else { return }
        self.website = website
        selectedPage?.webView.load(URLRequest(url: website))
    }

    func shutdown() {
        for page in pages { page.shutdown() }
        pages = []
        onFocus = nil
    }
}

@MainActor @Observable
final class SocialBrowserPage: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate,
    WKDownloadDelegate
{
    let id = UUID()
    let webView: SocialAccountWebView
    private(set) var title = "Website"
    private(set) var url: URL?
    private(set) var isLoading = true
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var error: String?
    var hoveredLink: URL?
    var showsFind = false
    var findText = ""
    private(set) var findMatched: Bool?
    private(set) var findFocusRequest = UUID()
    @ObservationIgnored var onOpenInBackground: ((URL) -> Void)?
    @ObservationIgnored var onPopup: ((WKWebViewConfiguration) -> WKWebView?)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var downloads: [ObjectIdentifier: WKDownload] = [:]
    @ObservationIgnored private var panels: [NSWindow] = []
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var requestedURL: URL?

    init(configuration: WKWebViewConfiguration) {
        webView = SocialAccountWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.onMenu = { [weak self] menu in self?.extend(menu) }
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
        ]
    }

    private func refresh() {
        title = webView.title ?? "Website"
        url = webView.url
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func retry() {
        error = nil
        if webView.url != nil {
            webView.reload()
        } else if let requestedURL {
            webView.load(URLRequest(url: requestedURL))
        }
    }

    func shutdown() {
        closed = true
        for panel in panels {
            panel.sheetParent?.endSheet(panel, returnCode: .cancel)
            panel.orderOut(nil)
        }
        panels = []
        for download in downloads.values { download.cancel { _ in } }
        downloads = [:]
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFocus = nil
        webView.onMenu = nil
        webView.removeFromSuperview()
        onPopup = nil
        onOpenInBackground = nil
        onClose = nil
    }

    func showFind() {
        showsFind = true
        findFocusRequest = UUID()
    }

    func hideFind() {
        showsFind = false
        findMatched = nil
        webView.window?.makeFirstResponder(webView)
    }

    func find(backwards: Bool = false) {
        guard !findText.isEmpty else {
            findMatched = nil
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(findText, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated { self?.findMatched = result.matchFound }
        }
    }

    func zoom(by step: Double) {
        webView.pageZoom = min(3, max(0.5, webView.pageZoom + step))
    }

    private func extend(_ menu: NSMenu) {
        WebContextMenu.retitle(menu)
        guard let scheme = webView.url?.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return }
        if let reload = index(of: "WKMenuItemIdentifierReload", in: menu) {
            for (offset, item) in [
                .separator(), action("Save Page As…", #selector(savePage)),
                action("Print…", #selector(printPage)),
            ].enumerated() {
                menu.insertItem(item, at: reload + 1 + offset)
            }
        }
        let source = action("View Page Source", #selector(viewSource))
        if let inspect = index(of: "WKMenuItemIdentifierInspectElement", in: menu) {
            menu.insertItem(source, at: inspect)
        } else {
            menu.addItem(.separator())
            menu.addItem(source)
        }
    }

    private func index(of identifier: String, in menu: NSMenu) -> Int? {
        menu.items.firstIndex { $0.identifier?.rawValue == identifier }
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func savePage() {
        guard !closed, let window = webView.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.webArchive]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".webarchive"
        panels.append(panel)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.panels.removeAll { $0 === panel }
            guard response == .OK, let destination = panel.url else { return }
            self.webView.createWebArchiveData { result in
                MainActor.assumeIsolated {
                    do {
                        try result.get().write(to: destination, options: .atomic)
                    } catch { self.failed(error) }
                }
            }
        }
    }

    @objc private func printPage() {
        guard !closed, let window = webView.window else { return }
        let operation = webView.printOperation(with: .shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc private func viewSource() {
        guard let url = webView.url else { return }
        Task {
            let source = try? await webView.callAsyncJavaScript(
                SocialPageSource.script, contentWorld: .defaultClient)
            guard !closed, let source = source as? String,
                let tab = onPopup?(WKWebViewConfiguration())
            else { return }
            tab.loadHTMLString(SocialPageSource.html(source, url: url), baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        error = failure.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = "This website stopped responding. Reload to continue in the same account."
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true { requestedURL = url }
        let scheme = url.scheme?.lowercased()
        let allowed =
            scheme == "https" || scheme == "http" || url.absoluteString == "about:blank"
            || scheme == "blob"
        if allowed, navigationAction.navigationType == .linkActivated,
            navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 4,
            let onOpenInBackground
        {
            onOpenInBackground(url)
            decisionHandler(.cancel)
            return
        }
        if !allowed, navigationAction.targetFrame?.isMainFrame != false {
            error =
                "This link opens an external application. Continue using the website in this account."
        }
        decisionHandler(
            allowed ? navigationAction.shouldPerformDownload ? .download : .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard !closed else { return nil }
        return onPopup?(configuration)
    }

    func webViewDidClose(_ webView: WKWebView) { onClose?() }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        guard !closed, let window = webView.window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panels.append(panel)
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.panels.removeAll { $0 === panel }
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        dialog(message, frame: frame, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        dialog(message, frame: frame, buttons: ["OK", "Cancel"]) {
            completionHandler($0 == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size = NSSize(width: 280, height: 24)
        dialog(prompt, frame: frame, buttons: ["OK", "Cancel"], field: field) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func dialog(
        _ message: String, frame: WKFrameInfo, buttons: [String], field: NSTextField? = nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard !closed, let window = webView.window else { completion(.abort); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        for title in buttons { alert.addButton(withTitle: title) }
        alert.accessoryView = field
        panels.append(alert.window)
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.panels.removeAll { $0 === alert.window }
            completion(response)
        }
    }

    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    func webView(
        _ webView: WKWebView, mouseDidMoveOver element: NSObject?,
        withFlags flags: NSEvent.ModifierFlags, userInfo: AnyObject?
    ) {
        let selector = NSSelectorFromString("absoluteLinkURL")
        let link =
            element?.responds(to: selector) == true
            ? element?.value(forKey: "absoluteLinkURL") as? URL : nil
        if hoveredLink != link { hoveredLink = link }
    }

    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreate download: WKDownload) {
        track(download)
    }

    func webView(
        _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
    ) {
        track(download)
    }

    func webView(
        _ webView: WKWebView, navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        track(download)
    }

    private func track(_ download: WKDownload) {
        downloads[ObjectIdentifier(download)] = download
        download.delegate = self
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String, completionHandler: @escaping (URL?) -> Void
    ) {
        guard !closed, let window = webView.window else { completionHandler(nil); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panels.append(panel)
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.panels.removeAll { $0 === panel }
            completionHandler(response == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        failed(error)
    }
}

@MainActor
final class SocialAccountWebView: WKWebView {
    var onFocus: (() -> Void)?
    var onMenu: ((NSMenu) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocus?()
        super.rightMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        onMenu?(menu)
    }
}

enum SocialPageSource {
    static let script = """
        try {
            const response = await fetch(location.href, { cache: "force-cache", credentials: "include" });
            return await response.text();
        } catch {
            return document.documentElement.outerHTML;
        }
        """

    static func html(_ source: String, url: URL) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<div>\(escape(String($0)))</div>" }.joined()
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <title>view-source:\(escape(url.absoluteString))</title>
            <style>
            :root{color-scheme:light dark}
            body{margin:0;padding:8px 0;font:12px ui-monospace,Menlo,monospace;counter-reset:line}
            div{white-space:pre-wrap;word-break:break-all;padding-left:5em;text-indent:-4em}
            div::before{counter-increment:line;content:counter(line);display:inline-block;width:3em;margin-right:1em;text-align:right;color:GrayText;text-indent:0}
            </style></head><body>\(lines)</body></html>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
