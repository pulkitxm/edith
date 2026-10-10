import AppKit
@_implementationOnly import GhosttyKit

public final class GhosttyTerminalView: NSView {
    public var onClose: ((Int32?) -> Void)?
    public var onOpenTarget: ((String, Bool) -> Bool)?
    public var onDropFiles: ((TerminalDropPayload) -> Bool)?
    public var onFocus: (() -> Void)?
    public var onFocusChange: ((Bool) -> Void)?
    public var onPaneAction: ((GhosttyPaneAction) -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?
    public var onReady: (() -> Void)?

    private(set) var surface: ghostty_surface_t?
    public internal(set) var currentDirectory: String?
    public internal(set) var hoveredLink: String?
    public let allowsLocalFileLinks: Bool
    private var externalIO: GhosttyExternalIO?
    private var externalExited = false
    let shouldResetTerminalAfterInterrupt: Bool
    private var theme: GhosttyTheme?
    private var themeConfig: ghostty_config_t?
    var temporaryDropFiles = Set<URL>()
    private var closed = false
    private var pendingExitCode: Int32?
    private var drawScheduled = false
    private(set) var renderingActive = true
    private(set) var secureInputRequested = false
    private var hostApplicationActive: Bool?
    private var hostWindowKey: Bool?
    var terminalCursor = NSCursor.iBeam
    var mouseOverSurface = false
    var commandClickOpenedTarget = false
    var commandClickGesture = TerminalCommandClickGesture()
    let linkHoverView = TerminalLinkHoverView(frame: .zero)
    let searchBar = TerminalSearchBar(frame: .zero)
    let progressStrip = TerminalProgressStrip(frame: .zero)
    let copyConfirmation = TerminalCopyConfirmationView(frame: .zero)
    var copyConfirmationTask: Task<Void, Never>?
    var searchTotal: Int?
    var searchSelected: Int?
    var accessibilitySelectionTask: Task<Void, Never>?
    let markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var localEventMonitor: Any?
    var suppressNextLeftMouseUp = false
    var focusMouseDown: NSEvent?
    var programOwnsMouseGesture = false
    var selectionMouseActive = false
    var selectionCopyPending = false
    var selectionMouseReportingSuspended = false
    private(set) var configuredMouseReporting = true
    private var windowObservers: [NSObjectProtocol] = []

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
        guard let surface, !closed, !externalExited, !text.isEmpty else { return false }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(strlen(pointer)))
        }
        return true
    }

    private(set) var focusRequested = false

    public func requestFocus() {
        focusRequested = true
        DispatchQueue.main.async { [weak self] in self?.claimRequestedFocus() }
    }

    public func cancelFocusRequest() {
        focusRequested = false
    }

    private func claimRequestedFocus() {
        guard focusRequested, let window else { return }
        focusRequested = false
        guard window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    @discardableResult
    public func requestClose() -> Bool {
        guard let surface, !closed else { return false }
        ghostty_surface_request_close(surface)
        return true
    }

    public override var wantsUpdateLayer: Bool { false }

    public init(
        externalIO: GhosttyExternalIO, workingDirectory: String? = nil,
        allowsLocalFileLinks: Bool = true, resetTerminalAfterInterrupt: Bool = false,
        theme: GhosttyTheme? = nil
    ) {
        self.externalIO = externalIO
        self.theme = theme
        currentDirectory = workingDirectory
        self.allowsLocalFileLinks = allowsLocalFileLinks
        shouldResetTerminalAfterInterrupt = resetTerminalAfterInterrupt
        super.init(frame: .zero)
        registerForDraggedTypes(Array(Self.dropTypes))
        addSubview(linkHoverView)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        progressStrip.translatesAutoresizingMaskIntoConstraints = false
        copyConfirmation.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchBar)
        addSubview(progressStrip)
        addSubview(copyConfirmation)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressStrip.topAnchor.constraint(equalTo: topAnchor),
            progressStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressStrip.heightAnchor.constraint(equalToConstant: 3),
            copyConfirmation.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            copyConfirmation.centerXAnchor.constraint(equalTo: centerXAnchor),
            copyConfirmation.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 8),
            copyConfirmation.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -8),
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
        copyConfirmationTask?.cancel()
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        removeWindowObservers()
        shutdown()
        GhosttySurfaceRegistry.shared.unregister(self)
    }

    public func shutdown() {
        copyConfirmationTask?.cancel()
        copyConfirmationTask = nil
        copyConfirmation.isHidden = true
        accessibilitySelectionTask?.cancel()
        accessibilitySelectionTask = nil
        focusMouseDown = nil
        programOwnsMouseGesture = false
        selectionMouseActive = false
        selectionCopyPending = false
        secureInputRequested = false
        GhosttySecureInput.shared.removeScoped(ObjectIdentifier(self))
        closed = true
        removeWindowObservers()
        externalIO?.invalidate()
        onFocusChange?(false)
        GhosttyRuntime.shared.setHostFocus(ObjectIdentifier(self), active: nil)
        if let surface {
            GhosttyRuntime.shared.drainPendingWork()
            ghostty_surface_free(surface)
            self.surface = nil
        }
        if let themeConfig {
            ghostty_config_free(themeConfig)
            self.themeConfig = nil
        }
        externalIO = nil
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
            if focusRequested {
                DispatchQueue.main.async { [weak self] in self?.claimRequestedFocus() }
            }
        } else {
            cancelSelectionGesture()
        }
        syncFocus()
        applyPresentationState()
    }

    private func startIfNeeded() {
        guard !closed, surface == nil, window != nil, !bounds.isEmpty, let externalIO else {
            return
        }
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

        var io = ghostty_external_io_s()
        io.userdata = Unmanaged.passUnretained(externalIO).toOpaque()
        io.write_cb = { userdata, bytes, count in
            guard let userdata else { return }
            Unmanaged<GhosttyExternalIO>.fromOpaque(userdata).takeUnretainedValue()
                .enqueue(bytes: bytes, count: count)
        }
        io.resize_cb = { userdata, columns, rows, width, height in
            guard let userdata else { return }
            Unmanaged<GhosttyExternalIO>.fromOpaque(userdata).takeUnretainedValue()
                .enqueue(columns: columns, rows: rows, width: width, height: height)
        }
        surface = withUnsafePointer(to: &io) { pointer in
            config.external_io = pointer
            return ghostty_surface_new(app, &config)
        }

        guard let surface else { return }
        updateConfiguredMouseReporting(GhosttyRuntime.shared.configHandle)
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
        updateConfiguredMouseReporting(config)
        if selectionMouseReportingSuspended, configuredMouseReporting {
            _ = performBindingAction("toggle_mouse_reporting")
        }
        if let themeConfig { ghostty_config_free(themeConfig) }
        themeConfig = config
        scheduleDraw()
    }

    private func updateConfiguredMouseReporting(_ config: ghostty_config_t?) {
        guard let config else { return }
        let key = "mouse-reporting"
        _ = ghostty_config_get(config, &configuredMouseReporting, key, UInt(key.utf8.count))
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

    @discardableResult
    public func receiveOutput(_ bytes: Data) -> Bool {
        guard let surface, !closed, !externalExited, !bytes.isEmpty, bytes.count <= 32_768 else {
            return false
        }
        let accepted = bytes.withUnsafeBytes { buffer in
            ghostty_surface_external_output(
                surface, buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        if accepted { scheduleDraw() }
        return accepted
    }

    @discardableResult
    public func setTermios(canonical: Bool, echo: Bool) -> Bool {
        guard let surface, !closed, !externalExited else { return false }
        return ghostty_surface_external_set_termios(surface, canonical, echo)
    }

    @discardableResult
    public func processExited(_ exitCode: Int32) -> Bool {
        guard let surface, !closed, !externalExited else { return false }
        pendingExitCode = exitCode
        externalExited = ghostty_surface_external_exit(surface)
        externalIO?.invalidate()
        scheduleDraw()
        return externalExited
    }

    func childExited(_ exitCode: Int32) {
        _ = processExited(exitCode)
    }

    func reportClosed(processAlive: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.handleClose(processAlive: processAlive)
        }
    }

    private func handleClose(processAlive _: Bool) {
        guard !closed else { return }
        finishClose()
    }

    private func finishClose() {
        guard !closed else { return }
        closed = true
        let exitCode = pendingExitCode
        let onClose = onClose
        shutdown()
        onClose?(exitCode)
    }

    private func applySize() {
        guard let surface, !bounds.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = UInt32(max(1, bounds.width * scale))
        let height = UInt32(max(1, bounds.height * scale))
        ghostty_surface_set_size(surface, width, height)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        startIfNeeded()
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
        isHidden = !active
        if !active {
            mouseOverSurface = false
            cancelSelectionGesture()
        }
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
            active: renderingActive && (hostApplicationActive ?? true),
            keyWindow: hostWindowKey ?? (window?.isKeyWindow == true),
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
                active: renderingActive && (hostApplicationActive ?? true),
                keyWindow: hostWindowKey ?? (window?.isKeyWindow == true),
                firstResponder: window?.firstResponder === self))
    }

    private func syncSecureInput(focused: Bool) {
        let identifier = ObjectIdentifier(self)
        if secureInputRequested {
            GhosttySecureInput.shared.setScoped(
                identifier, focused: focused, applicationActive: hostApplicationActive)
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

    var owningApplicationActive: Bool { hostApplicationActive ?? NSApp.isActive }
    var owningWindowKey: Bool { hostWindowKey ?? (window?.isKeyWindow == true) }

    public var hasInputFocus: Bool {
        !closed && renderingActive && window?.firstResponder === self
    }

    public func setHostWindowState(active: Bool, key: Bool) {
        guard !closed else { return }
        hostApplicationActive = active
        hostWindowKey = key
        GhosttyRuntime.shared.setHostFocus(ObjectIdentifier(self), active: active)
        syncFocus()
        onFocusChange?(hasInputFocus && active && key)
    }

    @discardableResult
    public func fontZoom(_ action: GhosttyFontZoom) -> Bool {
        guard !closed else { return false }
        switch action {
        case .increase: return performBindingAction("increase_font_size:1")
        case .decrease: return performBindingAction("decrease_font_size:1")
        case .reset: return performBindingAction("reset_font_size")
        }
    }

    func dispatchPaneAction(_ action: GhosttyPaneAction) -> Bool {
        guard !closed, onPaneAction != nil else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.onPaneAction?(action)
        }
        return true
    }

    static func shouldRender(active: Bool, hidden: Bool, windowVisible: Bool) -> Bool {
        active && !hidden && windowVisible
    }

    static func shouldFocus(active: Bool, keyWindow: Bool, firstResponder: Bool) -> Bool {
        active && keyWindow && firstResponder
    }

    public override func layout() {
        super.layout()
        startIfNeeded()
        applySize()
        scheduleDraw()
        linkHoverView.frame = bounds
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: terminalCursor)
    }

    public override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        let focused =
            renderingActive && (hostWindowKey ?? (window?.isKeyWindow == true))
            && (hostApplicationActive ?? true)
        if let surface { ghostty_surface_set_focus(surface, focused) }
        syncSecureInput(focused: focused)
        onFocusChange?(hasInputFocus)
        onFocus?()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        suppressNextLeftMouseUp = false
        cancelSelectionGesture()
        if let surface { ghostty_surface_set_focus(surface, false) }
        syncSecureInput(focused: false)
        onFocusChange?(false)
        return true
    }
}
