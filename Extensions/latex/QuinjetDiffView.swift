import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import WebKit

struct QuinjetDiffView: NSViewRepresentable {
    let patch: String
    let split: Bool
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let view = EditorWebView()
        view.setAccessibilityLabel("Quinjet changed files and diff")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        if let url = LaTeXEditorResources.reviewURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configure()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize?
    {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 500)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: QuinjetDiffView
        weak var view: WKWebView?
        private var ready = false
        private var lastConfiguration: Data?

        init(_ parent: QuinjetDiffView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            configure()
        }

        func configure() {
            guard ready, let view else { return }
            let options: [String: Any] = [
                "patch": parent.patch, "split": parent.split, "dark": parent.dark,
                "fontSize": UIScale.pt(13),
            ]
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: options, options: .sortedKeys),
                data != lastConfiguration
            else { return }
            lastConfiguration = data
            view.callAsyncJavaScript(
                "window.edithReview.configure(options)",
                arguments: ["options": options], in: nil, in: .page, completionHandler: nil)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                navigationAction.request.url == LaTeXEditorResources.reviewURL
                    && navigationAction.targetFrame?.isMainFrame != false ? .allow : .cancel)
        }
    }
}
