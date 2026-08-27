import AppKit
import GhosttyKit

public final class GhosttyTerminalView: NSView {
    public var onClose: (() -> Void)?
    public var onDropFiles: ((TerminalDropPayload) -> Bool)?
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?

    private(set) var surface: ghostty_surface_t?
    public internal(set) var currentDirectory: String?
    public internal(set) var hoveredLink: String?
    private var launch: GhosttyLaunch?
    private var theme: GhosttyTheme?
    private var themeConfig: ghostty_config_t?
    private var owned: GhosttyConfigStrings?
    var temporaryDropFiles = Set<URL>()
    private var closed = false
    private var drawScheduled = false
    var terminalCursor = NSCursor.iBeam
    var cursorHidden = false
    var commandClickReleaseActive = false
    var commandClickOpenedTarget = false
    var lastMousePoint: NSPoint?
    let linkHoverView = TerminalLinkHoverView(frame: .zero)

    public override var isFlipped: Bool { false }

    public override var acceptsFirstResponder: Bool { true }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

    public override var wantsUpdateLayer: Bool { false }

    public init(launch: GhosttyLaunch, theme: GhosttyTheme? = nil) {
        self.launch = launch
        self.theme = theme
        currentDirectory = launch.workingDirectory
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes(Array(Self.dropTypes))
        addSubview(linkHoverView)
        GhosttySurfaceRegistry.shared.register(self)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if cursorHidden { NSCursor.unhide() }
        shutdown()
        GhosttySurfaceRegistry.shared.unregister(self)
    }

    public func shutdown() {
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
        guard window != nil else { return }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard surface == nil, let launch else { return }
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
        ghostty_surface_set_focus(surface, window?.firstResponder === self)
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

    func reportClosed() {
        guard !closed else { return }
        closed = true
        onClose?()
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
        if let surface { ghostty_surface_set_focus(surface, true) }
        return true
    }

    public override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }
}
