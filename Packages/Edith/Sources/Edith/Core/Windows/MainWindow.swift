import AppKit
import EdithKit
import SwiftUI

struct ZoomableRoot<Content: View>: View {
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0
    @ViewBuilder let content: Content

    var body: some View {
        UIScale.apply(zoom)
        return
            content
            .font(.system(size: UIScale.pt(13)))
            .controlSize(UIScale.controlSize)
    }
}

@MainActor
enum MainWindow {
    private static var window: NSWindow?
    private static let updater = UpdaterModel(startingUpdater: !AgentService.usesCustomService)

    #if DEBUG
    private static var snapshotObserver: NSObjectProtocol?

    private static func installSnapshotHook() {
        guard snapshotObserver == nil else { return }
        snapshotObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPC.scopedName("com.pulkit.edith.debugSnapshot"), object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { snapshot() }
        }
    }

    private static func snapshot() {
        guard let window, let frameView = window.contentView?.superview,
            let layer = frameView.layer
        else { return }
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        guard
            let ctx = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "/tmp/edith-window.png"))
        let insets = window.contentView?.safeAreaInsets ?? NSEdgeInsets()
        let info = """
            frame=\(window.frame)
            contentLayoutRect=\(window.contentLayoutRect)
            toolbar=\(window.toolbar != nil) visible=\(window.toolbar?.isVisible ?? false)
            safeAreaTop=\(insets.top)
            """
        try? info.write(
            toFile: "/tmp/edith-debug.txt", atomically: true, encoding: .utf8)
    }
    #endif

    static func open() {
        #if DEBUG
        installSnapshotHook()
        #endif
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let visibleFrame =
            NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initialSize = MainWindowFramePolicy.defaultSize(visibleFrame: visibleFrame)
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [
                .titled, .closable, .resizable, .miniaturizable, .fullSizeContentView,
            ],
            backing: .buffered, defer: false)
        MainWindowFramePolicy.disableApplicationStateRestoration(w)
        w.title = "Edith"
        w.identifier = NSUserInterfaceItemIdentifier(MainWindowIdentifier.value)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.isReleasedWhenClosed = false
        w.setContentSize(initialSize)
        w.center()
        let autosaveName = "EdithMainWindow"
        if MainWindowFramePolicy.shouldDiscardAutosave(
            UserDefaults.standard.string(
                forKey: MainWindowFramePolicy.autosaveKey(name: autosaveName)))
        {
            NSWindow.removeFrame(usingName: autosaveName)
            UserDefaults.standard.removeObject(
                forKey: MainWindowFramePolicy.autosaveKey(name: autosaveName))
        }
        w.setFrameAutosaveName(autosaveName)
        let launchFrame = MainWindowFramePolicy.normalizedFrame(
            w.frame, visibleFrame: visibleFrame)
        if w.isZoomed { w.zoom(nil) }
        w.setFrame(launchFrame, display: false)
        w.contentMinSize = MainWindowFramePolicy.minimumSize(visibleFrame: visibleFrame)
        let hosting = NSHostingController(
            rootView: ZoomableRoot { MainWindowView(updater: updater) })
        hosting.sizingOptions = []
        w.contentViewController = hosting
        w.tabbingMode = .disallowed
        w.delegate = MainWindowDelegate.shared
        window = w
        w.makeKeyAndOrderFront(nil)
        if w.isZoomed { w.zoom(nil) }
        w.setFrame(launchFrame, display: true)
        w.saveFrame(usingName: autosaveName)
        NSApp.activate(ignoringOtherApps: true)
        if UserDefaults.standard.bool(forKey: AppStorageKeys.General.editMainWindowFullScreen),
            !w.styleMask.contains(.fullScreen)
        {
            w.toggleFullScreen(nil)
        }
    }

    static func forget() { window = nil }
}

enum MainWindowFramePolicy {
    @MainActor
    static func disableApplicationStateRestoration(_ window: NSWindow) {
        window.isRestorable = false
    }

    static func autosaveKey(name: String) -> String {
        "NSWindow Frame \(name)"
    }

    static func shouldDiscardAutosave(_ value: String?) -> Bool {
        value?.contains("tilingState") == true
    }

    static func minimumSize(visibleFrame: NSRect) -> NSSize {
        NSSize(
            width: min(960, visibleFrame.width),
            height: min(640, visibleFrame.height)
        )
    }

    static func defaultSize(visibleFrame: NSRect) -> NSSize {
        let minimum = minimumSize(visibleFrame: visibleFrame)
        return NSSize(
            width: min(1240, max(minimum.width, visibleFrame.width * 0.82)),
            height: min(820, max(minimum.height, visibleFrame.height * 0.78))
        )
    }

    static func normalizedFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
        let minimum = minimumSize(visibleFrame: visibleFrame)
        let undersized = frame.width < minimum.width || frame.height < minimum.height
        let size =
            undersized
            ? defaultSize(visibleFrame: visibleFrame)
            : NSSize(
                width: min(visibleFrame.width, frame.width),
                height: min(visibleFrame.height, frame.height)
            )
        let resized = size != frame.size
        let origin =
            resized
            ? NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2)
            : NSPoint(
                x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
                y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
            )
        return NSRect(origin: origin, size: size)
    }
}

enum MainWindowIdentifier {
    static let value = "EdithMainWindow"
}

@MainActor
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MainWindowDelegate()
    func windowWillClose(_ notification: Notification) {
        MainWindow.forget()
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: AppStorageKeys.General.editMainWindowFullScreen)
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: AppStorageKeys.General.editMainWindowFullScreen)
    }
}
