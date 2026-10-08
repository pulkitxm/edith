import AppKit
import EdithKit
import Observation
import SwiftUI
import WebKit

@MainActor @Observable
final class LaTeXEditorControls {
    var fontSize = 14.0
    var wrapsLines = true
    var line = 1
    var column = 1
    var canUndo = false
    var canRedo = false
    var ready = false
    @ObservationIgnored var webView: WKWebView?

    func undo() { command("undo") }
    func redo() { command("redo") }
    func find() { command("find") }

    func command(_ name: String) {
        webView?.callAsyncJavaScript(
            "window.edithEditor.command(name)", arguments: ["name": name], in: nil,
            in: .page, completionHandler: nil)
    }
}

struct LaTeXSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let controls: LaTeXEditorControls
    let dark: Bool
    let editable: Bool
    var documentID = ""
    var onSave: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let view: WKWebView
        if let retained = controls.webView {
            view = retained
        } else {
            view = EditorWebView(scrollSelector: ".cm-scroller")
            controls.webView = view
        }
        view.configuration.userContentController.removeScriptMessageHandler(forName: "latexEditor")
        view.configuration.userContentController.add(
            WeakScriptHandler(context.coordinator), name: "latexEditor")
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("LaTeX source editor")
        context.coordinator.view = view
        if controls.ready {
            context.coordinator.configure()
        } else if view.url == nil, !view.isLoading, let url = LaTeXEditorResources.url {
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
        CGSize(width: proposal.width ?? 500, height: proposal.height ?? 300)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        if (view.navigationDelegate as? Coordinator) === coordinator {
            view.configuration.userContentController.removeScriptMessageHandler(
                forName: "latexEditor")
            view.navigationDelegate = nil
        }
    }

    @MainActor private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?
        init(_ coordinator: Coordinator) { self.coordinator = coordinator }
        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            coordinator?.userContentController(controller, didReceive: message)
        }
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: LaTeXSourceEditor
        weak var view: WKWebView?
        private var ready = false
        private var lastConfiguration: Data?
        private var lastDocumentText: String?
        private var lastDocumentID: String?
        private var revision = 0

        init(_ parent: LaTeXSourceEditor) {
            self.parent = parent
            ready = parent.controls.ready
        }

        func configure() {
            guard ready, let view else { return }
            var options: [String: Any] = [
                "dark": parent.dark, "editable": parent.editable,
                "fontSize": UIScale.pt(parent.controls.fontSize),
                "wrapsLines": parent.controls.wrapsLines, "documentID": parent.documentID,
            ]
            let focuses = parent.documentID != lastDocumentID
            if parent.text != lastDocumentText || focuses {
                revision += 1
                options["text"] = parent.text
                lastDocumentText = parent.text
                lastDocumentID = parent.documentID
            }
            options["revision"] = revision
            guard
                let encoded = try? JSONSerialization.data(
                    withJSONObject: options, options: .sortedKeys),
                encoded != lastConfiguration
            else { return }
            lastConfiguration = encoded
            view.callAsyncJavaScript(
                "window.edithEditor.configure(options)", arguments: ["options": options], in: nil,
                in: .page, completionHandler: nil)
            if focuses {
                view.window?.makeFirstResponder(view)
                parent.controls.command("focus")
            }
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                let type = body["type"] as? String
            else { return }
            switch type {
            case "ready":
                ready = true
                parent.controls.ready = true
                configure()
            case "save":
                if body["revision"] as? Int == revision,
                    body["documentID"] as? String == parent.documentID, parent.editable
                {
                    parent.onSave()
                }
            case "state":
                guard body["revision"] as? Int == revision,
                    body["documentID"] as? String == parent.documentID
                else { return }
                if let text = body["text"] as? String {
                    lastDocumentText = text
                    if text != parent.text { parent.text = text }
                }
                parent.controls.line = body["line"] as? Int ?? 1
                parent.controls.column = body["column"] as? Int ?? 1
                parent.controls.canUndo = body["canUndo"] as? Bool ?? false
                parent.controls.canRedo = body["canRedo"] as? Bool ?? false
            default: break
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let allowed =
                action.request.url == LaTeXEditorResources.url
                && action.targetFrame?.isMainFrame != false
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}
