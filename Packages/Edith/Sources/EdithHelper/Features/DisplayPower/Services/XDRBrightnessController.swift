import AppKit
import EdithKit
import Metal
import QuartzCore

@MainActor
final class XDRBrightnessController {
    private(set) var supported = false
    private(set) var boosting = false
    private var overlayWindow: NSWindow?
    private var overlayLayer: CAMetalLayer?
    private var triggerWindow: NSWindow?
    private var triggerLayer: CAMetalLayer?
    private var queue: MTLCommandQueue?
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        self.changed = changed
    }

    func sync() {
        supported = Self.xdrScreen() != nil
        let enabled = SharedDefaults.store.bool(
            forKey: AppStorageKeys.DisplayPower.xdrBoostEnabled)
        if enabled, supported {
            start()
            render()
        } else {
            stop()
        }
        changed()
    }

    func shutdown() {
        stop()
    }

    private func start() {
        installObservers()
        guard timer == nil, let screen = Self.xdrScreen() else { return }
        showOverlay(on: screen)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        timer?.tolerance = 0.05
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
        workspaceObservers.removeAll()
        overlayWindow?.orderOut(nil)
        triggerWindow?.orderOut(nil)
        overlayWindow = nil
        overlayLayer = nil
        triggerWindow = nil
        triggerLayer = nil
        queue = nil
        screensAsleep = false
        boosting = false
    }

    private func installObservers() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspace.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAsleep = true }
            },
            workspace.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = false
                    self?.screenChanged()
                }
            },
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged() }
            },
        ]
    }

    private func screenChanged() {
        supported = Self.xdrScreen() != nil
        guard SharedDefaults.store.bool(forKey: AppStorageKeys.DisplayPower.xdrBoostEnabled),
            let screen = Self.xdrScreen()
        else {
            stop()
            changed()
            return
        }
        showOverlay(on: screen)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
                [weak self] _ in MainActor.assumeIsolated { self?.render() }
            }
        }
        render()
        changed()
    }

    private func showOverlay(on screen: NSScreen) {
        overlayWindow?.orderOut(nil)
        triggerWindow?.orderOut(nil)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { return }
        self.queue = queue
        let behavior: NSWindow.CollectionBehavior = [
            .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications, .canJoinAllSpaces,
            .stationary,
        ]
        let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        let window = NSWindow(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.level = level
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.sharingType = .none
        window.collectionBehavior = behavior
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.isOpaque = false
        layer.compositingFilter = "multiply"
        layer.drawableSize = CGSize(width: 2, height: 2)
        layer.frame = CGRect(origin: .zero, size: screen.frame.size)
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        overlayWindow = window
        overlayLayer = layer
        present(layer: layer, factor: 1.05, wait: true)
        window.orderFrontRegardless()

        let triggerFrame = NSRect(
            x: screen.frame.maxX - 1, y: screen.frame.minY, width: 1, height: 1)
        let trigger = NSWindow(
            contentRect: triggerFrame, styleMask: [.borderless], backing: .buffered,
            defer: false)
        trigger.level = level
        trigger.isOpaque = false
        trigger.backgroundColor = .clear
        trigger.hasShadow = false
        trigger.ignoresMouseEvents = true
        trigger.isReleasedWhenClosed = false
        trigger.animationBehavior = .none
        trigger.sharingType = .none
        trigger.collectionBehavior = behavior
        let triggerLayer = CAMetalLayer()
        triggerLayer.device = device
        triggerLayer.pixelFormat = .rgba16Float
        triggerLayer.wantsExtendedDynamicRangeContent = true
        triggerLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        triggerLayer.drawableSize = CGSize(width: 1, height: 1)
        triggerLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let triggerView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        triggerView.wantsLayer = true
        triggerView.layer = triggerLayer
        trigger.contentView = triggerView
        triggerWindow = trigger
        self.triggerLayer = triggerLayer
        present(layer: triggerLayer, factor: 1.8, wait: true)
        trigger.orderFrontRegardless()
    }

    private func render() {
        guard !screensAsleep, let screen = Self.xdrScreen(),
            let overlayLayer, let triggerLayer
        else { return }
        let rawLevel =
            SharedDefaults.store.object(
                forKey: AppStorageKeys.DisplayPower.xdrBoostLevel) as? Int ?? 50
        let level = DisplayPowerPolicy.normalizedBrightness(Double(rawLevel) / 100)
        let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        let factor =
            headroom > 1.05
            ? DisplayPowerPolicy.xdrFactor(level: level, currentHeadroom: headroom)
            : 1 + min(level * 0.1, 0.1)
        present(layer: triggerLayer, factor: 1.8)
        present(layer: overlayLayer, factor: factor)
        let visible = factor > 1.001
        if boosting != visible {
            boosting = visible
            changed()
        }
    }

    private func present(layer: CAMetalLayer, factor: Double, wait: Bool = false) {
        guard let queue, let drawable = layer.nextDrawable(),
            let commands = queue.makeCommandBuffer()
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: factor, green: factor, blue: factor, alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        if wait { commands.waitUntilScheduled() }
    }

    private static func xdrScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard
                let id =
                    (screen.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return false }
            return DisplayPowerPolicy.xdrSupported(
                builtIn: CGDisplayIsBuiltin(id) != 0, name: screen.localizedName,
                potentialHeadroom: Double(
                    screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                model: modelIdentifier)
        }
    }

    private static let modelIdentifier: String? = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }()
}
