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
            .id(UIScale.current)
    }
}

@MainActor
enum MainWindow {
    private static var window: NSWindow?
    private static let updater = UpdaterModel(startingUpdater: true)

    #if DEBUG
    private static var snapshotObserver: NSObjectProtocol?

    private static func installSnapshotHook() {
        guard snapshotObserver == nil else { return }
        snapshotObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.pulkit.edith.debugSnapshot"), object: nil,
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
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [
                .titled, .closable, .resizable, .miniaturizable, .fullSizeContentView,
            ],
            backing: .buffered, defer: false)
        w.title = "Edith"
        w.identifier = NSUserInterfaceItemIdentifier(MainWindowIdentifier.value)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 720, height: 500)
        let hosting = NSHostingController(
            rootView: ZoomableRoot { MainWindowView(updater: updater) })
        hosting.sizingOptions = []
        w.contentViewController = hosting
        w.setContentSize(NSSize(width: 900, height: 680))
        w.center()
        w.setFrameAutosaveName("EdithMainWindow")
        w.tabbingMode = .disallowed
        w.delegate = MainWindowDelegate.shared
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if UserDefaults.standard.bool(forKey: AppStorageKeys.General.editMainWindowFullScreen),
            !w.styleMask.contains(.fullScreen)
        {
            w.toggleFullScreen(nil)
        }
    }

    static func forget() { window = nil }
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
