import AppKit
import SwiftUI
import Testing
import WebKit

@testable import QuinjetUI
import EdithExtensionSupport
import EdithExtensionUI

@Suite(.serialized) @MainActor struct QuinjetDiffViewTests {
    @Test func offlineReviewSelectsFiltersAndRendersSafeHighlightedDiffs() async throws {
        _ = TestWindowHost.application
        let patch = #"""
            diff --git a/docs/main.tex b/docs/main.tex
            --- a/docs/main.tex
            +++ b/docs/main.tex
            @@ -1 +1 @@
            -\section{Draft}
            +\section{Paper <script>window.pwned=true</script>}
            diff --git a/build.yml b/build.yml
            --- a/build.yml
            +++ b/build.yml
            @@ -1 +1 @@
            -name: Draft
            +name: Paper
            """#
        let host = NSHostingView(rootView: QuinjetDiffView(patch: patch, split: false, dark: true))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func webView(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(webView).first
        }
        let view = try #require(webView(host))
        var count = 0
        for _ in 0..<50 {
            count =
                (try? await view.callAsyncJavaScript(
                    "return document.querySelectorAll('#files button').length", arguments: [:],
                    in: nil, contentWorld: .page) as? Int) ?? 0
            if count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(count == 2)
        #expect(!view.configuration.websiteDataStore.isPersistent)
        let safe =
            try await view.callAsyncJavaScript(
                "return window.pwned === undefined && document.querySelectorAll('script').length === 1",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(safe == true)
        let colored =
            try await view.callAsyncJavaScript(
                "return document.querySelector('.d2h-ins') !== null && document.querySelector('.hljs-tag, .hljs-keyword, .hljs-name') !== null",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(colored == true)
        _ = try await view.callAsyncJavaScript(
            "document.querySelectorAll('#files button')[1].click(); window.edithReview.configure({patch, split:true, dark:false, fontSize:16});",
            arguments: ["patch": patch], in: nil, contentWorld: .page)
        let selected =
            try await view.callAsyncJavaScript(
                "return document.querySelector('.d2h-file-name').textContent.includes('build.yml') && document.querySelector('.d2h-file-side-diff') !== null",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(selected == true)
        _ = try await view.callAsyncJavaScript(
            "document.querySelector('#filter').value='main.tex'; document.querySelector('#filter').dispatchEvent(new Event('input'));",
            arguments: [:], in: nil, contentWorld: .page)
        let filtered =
            try await view.callAsyncJavaScript(
                "return document.querySelectorAll('#files button').length === 1 && document.querySelector('#files button').textContent.includes('main.tex')",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(filtered == true)
    }
}
