import AppKit
import WebKit

@MainActor
final class NotchBrowserWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate,
    WKDownloadDelegate
{
    weak var store: NotchBrowserStore?

    init(store: NotchBrowserStore) {
        self.store = store
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        store?.policy(for: navigationAction, in: webView) ?? .allow
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        NotchBrowserStore.responsePolicy(navigationResponse)
    }

    func webView(
        _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView, navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store?.pageFinished(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        store?.popup(configuration: configuration, from: webView)
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.closeTab(for: webView)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        _ = await store?.present(.alert, message: message, frame: frame)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await store?.present(.confirm, message: message, frame: frame).0 ?? false
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard
            let (accepted, text) = await store?.present(
                .prompt(defaultText: defaultText ?? ""), message: prompt, frame: frame),
            accepted
        else { return nil }
        return text ?? ""
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        await store?.chooseFiles(parameters, window: webView.window)
    }

    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        store?.downloadDestination(for: download, suggestedFilename: suggestedFilename)
    }

    func downloadDidFinish(_ download: WKDownload) {
        store?.downloadFinished(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        store?.downloadFailed(download)
    }
}

@MainActor
final class NotchBrowserScriptProxy: NSObject, WKScriptMessageHandler {
    weak var store: NotchBrowserStore?

    init(store: NotchBrowserStore) {
        self.store = store
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == LocalStorageSeed.messageName, let origin = message.body as? String,
            message.frameInfo.isMainFrame,
            message.webView?.url.flatMap(BrowserTab.origin(of:)) == origin
        else { return }
        store?.seedApplied(origin: origin, in: message.webView)
    }
}
