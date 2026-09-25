import AppKit
import CoreGraphics
import Foundation
import WebKit

@MainActor
public final class WebCapture: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    private var continuation: CheckedContinuation<Void, Error>?

    public init(width: CGFloat) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let frame = CGRect(x: 0, y: 0, width: width, height: 900)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(
            contentRect: frame.offsetBy(dx: -30_000, dy: -30_000), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    nonisolated public static func target(from raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StudioError.invalidOption("url", "enter a web address") }
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let file = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw StudioError.unreadable(file.lastPathComponent)
            }
            return file
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            guard ["http", "https", "file"].contains(scheme) else {
                throw StudioError.invalidOption("url", "use an http or https address")
            }
            return url
        }
        guard let url = URL(string: "https://" + text), url.host?.contains(".") == true else {
            throw StudioError.invalidOption("url", "\(text) is not a web address")
        }
        return url
    }

    public func load(_ target: URL, timeout: TimeInterval = 45) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            if target.isFileURL {
                webView.loadFileURL(
                    target, allowingReadAccessTo: target.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: target, timeoutInterval: timeout))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(StudioError.failed("The page took too long to load."))
            }
        }
        try await settle()
    }

    private func settle() async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            let ready = try? await webView.evaluateJavaScript(
                "document.readyState === 'complete' && (!document.fonts || document.fonts.status === 'loaded')"
            )
            if (ready as? Bool) == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            webView.stopLoading()
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    public func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        finish(StudioError.failed("The page could not be loaded: \(error.localizedDescription)"))
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(StudioError.failed("The page could not be loaded: \(error.localizedDescription)"))
    }

    public func contentHeight() async -> CGFloat {
        let script =
            "Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight)"
        let value = try? await webView.evaluateJavaScript(script)
        let height = (value as? NSNumber)?.doubleValue ?? 900
        return CGFloat(max(1, height))
    }

    public var title: String? { webView.title }

    public func pdf() async throws -> Data {
        let height = await contentHeight()
        resize(height: min(height, 30_000))
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0, y: 0, width: webView.bounds.width, height: min(height, 30_000))
        return try await webView.pdf(configuration: configuration)
    }

    public func snapshot(fullPage: Bool, maxHeight: CGFloat = 16_000) async throws -> CGImage {
        let height = fullPage ? min(await contentHeight(), maxHeight) : webView.bounds.height
        resize(height: height)
        try await Task.sleep(nanoseconds: 150_000_000)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw StudioError.failed("The page could not be captured.")
        }
        return cgImage
    }

    private func resize(height: CGFloat) {
        let frame = CGRect(x: 0, y: 0, width: webView.bounds.width, height: max(1, height))
        window.setContentSize(frame.size)
        webView.frame = frame
        webView.layoutSubtreeIfNeeded()
    }

    public func close() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        window.contentView = nil
        window.close()
    }
}

public enum WebPDFLayout {
    public static func paginate(
        _ data: Data, paper: CGSize?, margin: CGFloat, title: String, to url: URL
    ) throws -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider), document.numberOfPages > 0
        else { throw StudioError.failed("The page could not be turned into a PDF.") }
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title, kCGPDFContextCreator: "Edith Studio",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw StudioError.failed("Could not create \(url.lastPathComponent).")
        }
        var pages = 0
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index) else { continue }
            let source = page.getBoxRect(.mediaBox)
            guard let paper else {
                var box = CGRect(origin: .zero, size: source.size)
                context.beginPage(mediaBox: &box)
                context.translateBy(x: -source.minX, y: -source.minY)
                context.drawPDFPage(page)
                context.endPage()
                pages += 1
                continue
            }
            let content = CGSize(
                width: paper.width - margin * 2, height: paper.height - margin * 2)
            let scale = min(1, content.width / max(source.width, 1))
            let slice = content.height / scale
            var offset: CGFloat = 0
            var box = CGRect(origin: .zero, size: paper)
            repeat {
                context.beginPage(mediaBox: &box)
                context.saveGState()
                context.clip(
                    to: CGRect(x: margin, y: margin, width: content.width, height: content.height))
                context.translateBy(x: margin, y: margin)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -source.minX, y: -(source.maxY - offset - slice))
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPage()
                pages += 1
                offset += slice
            } while offset < source.height - 1 && pages < 2000
        }
        context.closePDF()
        return pages
    }
}
