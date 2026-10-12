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
            let ready = try await evaluate(
                "document.readyState === 'complete' && (!document.fonts || document.fonts.status === 'loaded')"
            )
            if (ready as? Bool) == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    static let unresponsive = StudioError.failed(
        "The page stopped responding. It may be running a script that never finishes.")

    func evaluate(_ script: String, timeout: TimeInterval = 8) async throws -> Any? {
        try await bounded(timeout: timeout) { finish in
            self.webView.evaluateJavaScript(script) { value, _ in finish(.success(value)) }
        }
    }

    func bounded<Value>(
        timeout: TimeInterval,
        _ start: @escaping (@escaping (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Value, Error>) in
            var done = false
            let finish: (Result<Value, Error>) -> Void = { result in
                guard !done else { return }
                done = true
                continuation.resume(with: result)
            }
            start(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(Self.unresponsive))
            }
        }
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

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(StudioError.failed("The page crashed while loading."))
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

    public func contentHeight() async throws -> CGFloat {
        let script =
            "Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight)"
        let value = try await evaluate(script)
        let height = (value as? NSNumber)?.doubleValue ?? 900
        return CGFloat(max(1, height))
    }

    public var title: String? { webView.title }

    public struct Measurement {
        public var height: CGFloat
        public var boxes: [(CGFloat, CGFloat)]
        public var hasContent: Bool
        public var truncated: Bool
    }

    static let measureScript = """
        (() => {
          const boxes = [];
          const root = document.body || document.documentElement;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          const range = document.createRange();
          let characters = 0;
          while (walker.nextNode()) {
            const node = walker.currentNode;
            const trimmed = node.textContent.trim();
            if (!trimmed) continue;
            const parent = node.parentElement;
            if (parent && ['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(parent.tagName)) continue;
            range.selectNodeContents(node);
            for (const rect of range.getClientRects()) {
              if (rect.height > 0 && rect.width > 0) {
                characters += 1;
                boxes.push([rect.top + window.scrollY, rect.bottom + window.scrollY]);
              }
            }
          }
          let media = 0;
          for (const element of document.querySelectorAll('img,svg,canvas,video,iframe,object,embed,tr')) {
            const rect = element.getBoundingClientRect();
            if (rect.height > 0 && rect.width > 0) {
              if (element.tagName !== 'TR') media += 1;
              boxes.push([rect.top + window.scrollY, rect.bottom + window.scrollY]);
            }
          }
          let painted = 0;
          for (const element of root.querySelectorAll('*')) {
            const style = getComputedStyle(element);
            if (style.backgroundImage !== 'none' || (style.backgroundColor !== 'rgba(0, 0, 0, 0)' && style.backgroundColor !== 'transparent')) { painted += 1; break; }
          }
          const height = Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight);
          return JSON.stringify({ boxes: boxes, characters: characters, media: media + painted, height: height });
        })()
        """

    public func measure(maxHeight: CGFloat) async throws -> Measurement {
        var height = try await contentHeight()
        for _ in 0..<3 {
            let target = min(height, maxHeight)
            guard abs(webView.bounds.height - target) > 0.5 else { break }
            resize(height: target)
            try await Task.sleep(nanoseconds: 60_000_000)
            height = try await contentHeight()
        }
        let raw = try await evaluate(Self.measureScript, timeout: 20)
        var boxes: [(CGFloat, CGFloat)] = []
        var hasContent = true
        if let text = raw as? String, let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for pair in object["boxes"] as? [[Double]] ?? [] where pair.count == 2 {
                boxes.append((CGFloat(pair[0]), CGFloat(pair[1])))
            }
            let characters = (object["characters"] as? NSNumber)?.intValue ?? 0
            let media = (object["media"] as? NSNumber)?.intValue ?? 0
            hasContent = characters + media > 0
            if let measured = (object["height"] as? NSNumber)?.doubleValue {
                height = CGFloat(max(1, measured))
            }
        }
        let captured = min(height, maxHeight, webView.bounds.height)
        return Measurement(
            height: captured, boxes: boxes, hasContent: hasContent,
            truncated: height > captured + 1)
    }

    public func pdf(rect: CGRect) async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        return try await bounded(timeout: 60) { finish in
            self.webView.createPDF(configuration: configuration) { finish($0) }
        }
    }

    public func snapshot(fullPage: Bool, maxHeight: CGFloat = 32_000) async throws -> (
        image: CGImage, truncated: Bool
    ) {
        let width = webView.bounds.width
        var height = webView.bounds.height
        var truncated = false
        if fullPage {
            let measurement = try await measure(maxHeight: maxHeight)
            height = measurement.height
            truncated = measurement.truncated
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let pixelWidth = Int(width.rounded())
        let pixelHeight = Int(max(1, height).rounded())
        guard
            let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw StudioError.failed("The page is too large to capture.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        let tile: CGFloat = 4096
        var top: CGFloat = 0
        while top < CGFloat(pixelHeight) {
            try Task.checkCancellation()
            let slice = min(tile, CGFloat(pixelHeight) - top)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: top, width: width, height: slice)
            configuration.snapshotWidth = NSNumber(value: Double(width))
            configuration.afterScreenUpdates = true
            let image: NSImage = try await bounded(timeout: 60) { finish in
                self.webView.takeSnapshot(with: configuration) { image, error in
                    if let image {
                        finish(.success(image))
                    } else {
                        finish(
                            .failure(
                                error ?? StudioError.failed("The page could not be captured.")))
                    }
                }
            }
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw StudioError.failed("The page could not be captured.")
            }
            context.draw(
                cgImage,
                in: CGRect(
                    x: 0, y: CGFloat(pixelHeight) - top - slice, width: CGFloat(pixelWidth),
                    height: slice))
            top += slice
        }
        guard let image = context.makeImage() else {
            throw StudioError.failed("The page could not be captured.")
        }
        return (image, truncated)
    }

    private func resize(height: CGFloat) {
        let frame = CGRect(x: 0, y: 0, width: webView.bounds.width, height: max(1, height))
        window.setContentSize(frame.size)
        webView.frame = frame
        webView.layoutSubtreeIfNeeded()
        webView.needsDisplay = true
    }

    public func close() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        window.contentView = nil
        window.close()
    }
}

public enum WebPDFLayout {
    public static func breaks(
        height: CGFloat, slice: CGFloat, avoiding boxes: [(CGFloat, CGFloat)]
    ) -> [CGFloat] {
        guard height > 0, slice > 0 else { return [0, max(height, 0)] }
        var merged: [(CGFloat, CGFloat)] = []
        for box in boxes.sorted(by: { $0.0 < $1.0 }) where box.1 > box.0 {
            if let last = merged.last, box.0 < last.1 - 0.5 {
                merged[merged.count - 1].1 = max(last.1, box.1)
            } else {
                merged.append(box)
            }
        }
        var cuts: [CGFloat] = [0]
        var top: CGFloat = 0
        while top < height - 0.5, cuts.count < 20_000 {
            var cut = top + slice
            if cut >= height - 0.5 {
                cuts.append(height)
                break
            }
            var moved = true
            while moved {
                moved = false
                for box in merged where box.0 < cut - 0.25 && box.1 > cut + 0.25 {
                    guard box.1 - box.0 <= slice, box.0 > top + slice * 0.25 else { continue }
                    cut = box.0
                    moved = true
                }
            }
            cuts.append(cut)
            top = cut
        }
        return cuts
    }

    @MainActor
    public static func render(
        _ capture: WebCapture, paper: CGSize?, margin: CGFloat, title: String, label: String,
        to url: URL, progress: (Double) -> Void = { _ in }
    ) async throws -> (pages: Int, truncated: Bool) {
        let measurement = try await capture.measure(maxHeight: 400_000)
        guard measurement.hasContent else {
            throw StudioError.nothingToDo("\(label) has no content to save.")
        }
        let width = capture.webView.bounds.width
        let scale: CGFloat
        let slice: CGFloat
        if let paper {
            let content = CGSize(width: paper.width - margin * 2, height: paper.height - margin * 2)
            scale = min(1, content.width / max(width, 1))
            slice = content.height / scale
        } else {
            scale = 1
            slice = 14_400
        }
        let cuts = breaks(height: measurement.height, slice: slice, avoiding: measurement.boxes)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title, kCGPDFContextCreator: "Edith Studio",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw StudioError.failed("Could not create \(url.lastPathComponent).")
        }
        var pages = 0
        for (index, (top, bottom)) in zip(cuts, cuts.dropFirst()).enumerated() {
            try Task.checkCancellation()
            let rect = CGRect(x: 0, y: top, width: width, height: max(1, bottom - top))
            let data = try await capture.pdf(rect: rect)
            guard let provider = CGDataProvider(data: data as CFData),
                let document = CGPDFDocument(provider), let page = document.page(at: 1)
            else { throw StudioError.failed("The page could not be turned into a PDF.") }
            let source = page.getBoxRect(.mediaBox)
            var box = CGRect(origin: .zero, size: paper ?? source.size)
            context.beginPage(mediaBox: &box)
            context.saveGState()
            if paper != nil {
                let drawn = CGSize(width: source.width * scale, height: source.height * scale)
                let origin = CGPoint(x: margin, y: box.height - margin - drawn.height)
                context.clip(to: CGRect(origin: origin, size: drawn))
                context.translateBy(x: origin.x, y: origin.y)
                context.scaleBy(x: scale, y: scale)
            }
            context.translateBy(x: -source.minX, y: -source.minY)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPage()
            pages += 1
            progress(Double(index + 1) / Double(max(cuts.count - 1, 1)))
        }
        context.closePDF()
        return (pages, measurement.truncated)
    }
}
