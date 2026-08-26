import AppKit
import GhosttyKit

public final class GhosttyTerminalView: NSView {
    public var onClose: (() -> Void)?

    private(set) var surface: ghostty_surface_t?
    private var launch: GhosttyLaunch?
    private var theme: GhosttyTheme?
    private var themeConfig: ghostty_config_t?
    private var owned: GhosttyConfigStrings?
    private var closed = false
    private var drawScheduled = false

    public override var isFlipped: Bool { false }

    public override var acceptsFirstResponder: Bool { true }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func focusIfNeeded() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    public override var wantsUpdateLayer: Bool { false }

    public init(launch: GhosttyLaunch, theme: GhosttyTheme? = nil) {
        self.launch = launch
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        GhosttySurfaceRegistry.shared.register(self)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let surface { ghostty_surface_free(surface) }
        if let themeConfig { ghostty_config_free(themeConfig) }
        GhosttySurfaceRegistry.shared.unregister(self)
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
