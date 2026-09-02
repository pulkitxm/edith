import AppKit
import GhosttyKit

public final class GhosttyTerminalView: NSView {
    public var onClose: ((Int32?) -> Void)?
    public var onCloseRequestCancelled: (() -> Void)?
    public var onDropFiles: ((TerminalDropPayload) -> Bool)?
    public var onFocus: (() -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?
    public var onReady: (() -> Void)?

    private(set) var surface: ghostty_surface_t?
    public internal(set) var currentDirectory: String?
    public internal(set) var hoveredLink: String?
    public let allowsLocalFileLinks: Bool
    private var launch: GhosttyLaunch?
    var shouldResetTerminalAfterInterrupt: Bool {
        launch?.resetTerminalAfterInterrupt == true
    }
    private var theme: GhosttyTheme?
    private var themeConfig: ghostty_config_t?
    private var owned: GhosttyConfigStrings?
    var temporaryDropFiles = Set<URL>()
    private var closed = false
    private var closePromptVisible = false
    private var closeAlert: NSAlert?
    private var pendingExitCode: Int32?
    private var drawScheduled = false
    private(set) var renderingActive = true
    private var secureInputRequested = false
    var terminalCursor = NSCursor.iBeam
    var mouseOverSurface = false
    var commandClickOpenedTarget = false
    var commandClickGesture = TerminalCommandClickGesture()
    let linkHoverView = TerminalLinkHoverView(frame: .zero)
    let searchBar = TerminalSearchBar(frame: .zero)
    let progressStrip = TerminalProgressStrip(frame: .zero)
    var searchTotal: Int?
    var searchSelected: Int?
    var accessibilitySelectionTask: Task<Void, Never>?
    let markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var localEventMonitor: Any?
    var suppressNextLeftMouseUp = false
    private var windowObservers: [NSObjectProtocol] = []
    var openResolvedURL: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    public override var isFlipped: Bool { false }

    public override var acceptsFirstResponder: Bool { true }

    public var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    public func selectedText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: raw, count: Int(text.text_len)), as: UTF8.self)
    }

    @discardableResult
    public func insertText(_ text: String) -> Bool {
        guard let surface, !text.isEmpty else { return false }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(strlen(pointer)))
        }
        return true
    }

    public func focusIfNeeded() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    @discardableResult
    public func requestClose() -> Bool {
        guard let surface, !closed else { return false }
        ghostty_surface_request_close(surface)
        return true
    }

    public override var wantsUpdateLayer: Bool { false }

    public init(launch: GhosttyLaunch, theme: GhosttyTheme? = nil) {
        self.launch = launch
        self.theme = theme
        currentDirectory = launch.workingDirectory
        allowsLocalFileLinks = launch.allowsLocalFileLinks
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes(Array(Self.dropTypes))
        addSubview(linkHoverView)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        progressStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchBar)
        addSubview(progressStrip)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressStrip.topAnchor.constraint(equalTo: topAnchor),
            progressStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressStrip.heightAnchor.constraint(equalToConstant: 3),
        ])
        searchBar.onQuery = { [weak self] query in
            _ = self?.performBindingAction("search:\(query)")
        }
        searchBar.onNavigate = { [weak self] previous in
            _ = self?.performBindingAction(
                previous ? "navigate_search:previous" : "navigate_search:next")
        }
        searchBar.onClose = { [weak self] in
            _ = self?.performBindingAction("end_search")
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) {
            [weak self] event in
            self?.handleLocalEvent(event) ?? event
        }
        GhosttySurfaceRegistry.shared.register(self)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        accessibilitySelectionTask?.cancel()
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        removeWindowObservers()
        shutdown()
        GhosttySurfaceRegistry.shared.unregister(self)
    }

    public func shutdown() {
        secureInputRequested = false
        GhosttySecureInput.shared.removeScoped(ObjectIdentifier(self))
        closed = true
        removeWindowObservers()
        closePromptVisible = false
        if let closeAlert, let parent = closeAlert.window.sheetParent {
            parent.endSheet(closeAlert.window, returnCode: .cancel)
        }
        closeAlert = nil
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        if let themeConfig {
            ghostty_config_free(themeConfig)
            self.themeConfig = nil
        }
        owned = nil
        TerminalDropPayload(files: [], temporaryFiles: temporaryDropFiles).removeTemporaryFiles()
        temporaryDropFiles.removeAll()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        mouseOverSurface = false
        if let window {
            window.acceptsMouseMovedEvents = true
            observeWindow(window)
            startIfNeeded()
        }
        syncFocus()
        applyPresentationState()
    }

    private func startIfNeeded() {
        guard !closed, surface == nil, let launch else { return }
        GhosttyRuntime.shared.start()
        guard let app = GhosttyRuntime.shared.handle else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB
        config.wait_after_command = false

        owned = GhosttyConfigStrings(launch: launch)
        config.command = owned?.command
        config.working_directory = owned?.workingDirectory
        if let owned, !owned.environment.isEmpty {
            owned.environment.withUnsafeBufferPointer { buffer in
                config.env_vars = UnsafeMutablePointer(mutating: buffer.baseAddress)
                config.env_var_count = buffer.count
                surface = ghostty_surface_new(app, &config)
            }
        } else {
            surface = ghostty_surface_new(app, &config)
        }

        guard let surface else { return }
        applyTheme()
        ghostty_surface_set_content_scale(
            surface, config.scale_factor, config.scale_factor)
        applySize()
        syncFocus()
        applyPresentationState()
        onReady?()
    }

    public func apply(theme newTheme: GhosttyTheme) {
        guard theme != newTheme else { return }
        theme = newTheme
        applyTheme()
    }

    private func applyTheme() {
        guard let surface, let theme else { return }
        guard let config = GhosttyRuntime.shared.configuration(for: theme) else { return }
        ghostty_surface_update_config(surface, config)
        if let themeConfig { ghostty_config_free(themeConfig) }
        themeConfig = config
        scheduleDraw()
    }

    func scheduleDraw() {
        guard !drawScheduled else { return }
        drawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawScheduled = false
            guard let surface = self.surface, self.window != nil else { return }
            ghostty_surface_draw(surface)
        }
    }

    func childExited(_ exitCode: Int32) {
        pendingExitCode = exitCode
        DispatchQueue.main.async { [weak self] in
            guard let surface = self?.surface else { return }
            ghostty_surface_request_close(surface)
        }
    }

    func reportClosed(processAlive: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.handleClose(processAlive: processAlive)
        }
    }

    private func handleClose(processAlive: Bool) {
        guard !closed else { return }
        guard processAlive else {
            finishClose()
            return
        }
        guard !closePromptVisible else { return }
        closePromptVisible = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Terminal?"
        alert.informativeText =
            "The terminal still has a running process. Closing it will stop that process."
        alert.addButton(withTitle: "Close Terminal")
        alert.addButton(withTitle: "Cancel")
        closeAlert = alert
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.closePromptVisible else { return }
            self.closePromptVisible = false
            self.closeAlert = nil
            if response == .alertFirstButtonReturn {
                self.finishClose()
            } else {
                self.onCloseRequestCancelled?()
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func finishClose() {
        guard !closed else { return }
        closed = true
        closePromptVisible = false
        if let closeAlert, let parent = closeAlert.window.sheetParent {
            parent.endSheet(closeAlert.window, returnCode: .cancel)
        }
        closeAlert = nil
        let exitCode = pendingExitCode
        let onClose = onClose
        shutdown()
        onClose?(exitCode)
    }

    private func applySize() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = UInt32(max(1, bounds.width * scale))
        let height = UInt32(max(1, bounds.height * scale))
        ghostty_surface_set_size(surface, width, height)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applySize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(surface, scale, scale)
        applySize()
        applyPresentationState()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        applyPresentationState()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        applyPresentationState()
    }

    public func setRenderingActive(_ active: Bool) {
        guard renderingActive != active else { return }
        renderingActive = active
        if !active { mouseOverSurface = false }
        syncFocus()
        applyPresentationState()
    }

    private func observeWindow(_ window: NSWindow) {
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            windowObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.syncFocus()
                    self?.applyPresentationState()
                })
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
    }

    private func syncFocus() {
        let focused = Self.shouldFocus(
            active: renderingActive, keyWindow: window?.isKeyWindow == true,
            firstResponder: window?.firstResponder === self)
        if !focused { suppressNextLeftMouseUp = false }
        if let surface { ghostty_surface_set_focus(surface, focused) }
        syncSecureInput(focused: focused)
    }

    func setSecureInput(_ mode: ghostty_action_secure_input_e) {
        switch mode {
        case GHOSTTY_SECURE_INPUT_ON:
            secureInputRequested = true
        case GHOSTTY_SECURE_INPUT_OFF:
            secureInputRequested = false
        case GHOSTTY_SECURE_INPUT_TOGGLE:
            secureInputRequested.toggle()
        default:
            return
        }
        syncSecureInput(
            focused: Self.shouldFocus(
                active: renderingActive, keyWindow: window?.isKeyWindow == true,
                firstResponder: window?.firstResponder === self))
    }

    private func syncSecureInput(focused: Bool) {
        let identifier = ObjectIdentifier(self)
        if secureInputRequested {
            GhosttySecureInput.shared.setScoped(identifier, focused: focused)
        } else {
            GhosttySecureInput.shared.removeScoped(identifier)
        }
    }

    private func applyPresentationState() {
        guard let surface else { return }
        let visible = Self.shouldRender(
            active: renderingActive, hidden: isHidden,
            windowVisible: window?.occlusionState.contains(.visible) == true)
        ghostty_surface_set_occlusion(surface, visible)
        if let number = window?.screen?.deviceDescription[.init("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, number.uint32Value)
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(
            surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    static func shouldRender(active: Bool, hidden: Bool, windowVisible: Bool) -> Bool {
        active && !hidden && windowVisible
    }

    static func shouldFocus(active: Bool, keyWindow: Bool, firstResponder: Bool) -> Bool {
        active && keyWindow && firstResponder
    }

    public override func layout() {
        super.layout()
        linkHoverView.frame = bounds
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: terminalCursor)
    }

    public override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        let focused = renderingActive && window?.isKeyWindow == true
        if let surface { ghostty_surface_set_focus(surface, focused) }
        syncSecureInput(focused: focused)
        onFocus?()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        suppressNextLeftMouseUp = false
        if let surface { ghostty_surface_set_focus(surface, false) }
        syncSecureInput(focused: false)
        return true
    }
}
