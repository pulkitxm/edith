import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import WebKit

enum QuinjetDiffColors {
    static func options(dark: Bool, theme: AppTheme) -> [String: String] {
        let surface = srgb(DashSkin.paper2(dark))
        let ink = srgb(DashSkin.ink(dark))
        let accent = srgb(DashSkin.accent(dark, theme: theme))
        return [
            "surface": DiffHex.string(surface),
            "ink": DiffHex.string(ink),
            "muted": DiffHex.string(srgb(DashSkin.inkSoft(dark))),
            "border": DiffHex.string(srgb(DashSkin.line(dark))),
            "accent": DiffHex.string(mix(accent, dark ? .white : .black, by: 0.2)),
            "raised": DiffHex.string(mix(surface, ink, by: dark ? 0.06 : 0.04)),
            "selected": DiffHex.string(mix(surface, accent, by: dark ? 0.3 : 0.18)),
        ]
    }

    private static func srgb(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? .black
    }

    private static func mix(_ base: NSColor, _ target: NSColor, by fraction: CGFloat) -> NSColor {
        base.blended(withFraction: fraction, of: target) ?? base
    }
}

private enum DiffHex {
    static func string(_ color: NSColor) -> String {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return String(
            format: "#%02x%02x%02x", Int((resolved.redComponent * 255).rounded()),
            Int((resolved.greenComponent * 255).rounded()),
            Int((resolved.blueComponent * 255).rounded()))
    }
}

struct QuinjetDiffView: NSViewRepresentable {
    let patch: String
    let split: Bool
    let dark: Bool
    var theme = ThemeStore.current

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let view = EditorWebView()
        view.setAccessibilityLabel("Quinjet changed files and diff")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        if let url = QuinjetResources.reviewURL {
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
                "colors": QuinjetDiffColors.options(dark: parent.dark, theme: parent.theme),
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
                navigationAction.request.url == QuinjetResources.reviewURL
                    && navigationAction.targetFrame?.isMainFrame != false ? .allow : .cancel)
        }
    }
}
