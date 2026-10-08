import WebKit

final class EditorWebView: WKWebView {
    private var wheelMonitor: Any?

    init() {
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
                self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            else { return event }
            self.scrollWheel(with: event)
            return nil
        }
    }

    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }
}
