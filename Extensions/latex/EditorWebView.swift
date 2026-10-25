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
                let point = self.convert(event.locationInWindow, from: nil)
                self.callAsyncJavaScript(
                    """
                    let scroller;
                    for (let node = document.elementFromPoint(pointerX, pointerY); node; node = node.parentElement) {
                        const style = getComputedStyle(node);
                        if ((/auto|scroll/.test(style.overflowY) && node.scrollHeight > node.clientHeight)
                            || (/auto|scroll/.test(style.overflowX) && node.scrollWidth > node.clientWidth)) {
                            scroller = node;
                            break;
                        }
                    }
                    (scroller ?? document.querySelector(selector))?.scrollBy({left:x, top:y, behavior:'instant'});
                    """,
                    arguments: [
                        "selector": selector, "x": -event.scrollingDeltaX * scale,
                        "y": -event.scrollingDeltaY * scale,
                        "pointerX": point.x - self.bounds.minX,
                        "pointerY": self.isFlipped
                            ? point.y - self.bounds.minY : self.bounds.maxY - point.y,
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
