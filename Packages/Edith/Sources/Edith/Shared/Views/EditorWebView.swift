import WebKit

final class EditorWebView: WKWebView {
    private var wheelMonitor: Any?
    private let scrollSelector: String?

    init(scrollSelector: String? = nil) {
        self.scrollSelector = scrollSelector
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                self.visibleRect.contains(self.convert(event.locationInWindow, from: nil))
            else { return event }
            if let selector = self.scrollSelector {
                let scale = event.hasPreciseScrollingDeltas ? 1.0 : 40.0
                self.callAsyncJavaScript(
                    "document.querySelector(selector)?.scrollBy({left:x, top:y, behavior:'instant'})",
                    arguments: [
                        "selector": selector, "x": -event.scrollingDeltaX * scale,
                        "y": -event.scrollingDeltaY * scale,
                    ], in: nil, in: .page, completionHandler: nil)
            } else {
                self.scrollWheel(with: event)
            }
            return nil
        }
    }

    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }
}
