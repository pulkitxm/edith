import AppKit
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SectionWindowController {
    var destination: MainDestination

    init(destination: MainDestination) {
        self.destination = destination
    }
}

struct DetachedSectionView: View {
    let controller: SectionWindowController
    @State private var router = WindowRouter()
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationRouteHost(router: router) {
            GeometryReader { geo in
                detail
                    .tint(themeColor(themeName))
                    .environment(\.compactLayout, geo.size.width < UIScale.pt(640))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DashSkin.paper(scheme == .dark))
            }
            .navigationRoute(
                "section", selection: sectionBinding,
                isValid: { $0.isEmpty || $0 == controller.destination.rawValue })
        }
    }

    private var sectionBinding: Binding<String> {
        Binding(get: { controller.destination.rawValue }, set: { _ in })
    }

    private var detail: some View {
        PageContent(controller.destination, updater: UpdaterModel())
    }
}

enum SectionOpenMode {
    case reuseMostRecent
    case alwaysNew
}

@MainActor
enum SectionWindow {
    private struct Entry {
        let window: NSWindow
        let controller: SectionWindowController
    }

    private static var entries: [Entry] = []

    static var openDestinations: [MainDestination] {
        entries.map { $0.controller.destination }
    }

    static func isShowingSomewhere(_ destination: MainDestination) -> Bool {
        entries.contains { $0.controller.destination == destination }
    }

    static func focusOrSelect(_ destination: MainDestination) {
        if focusExisting(destination) { return }
        SharedDefaults.store.set(
            destination.rawValue, forKey: AppStorageKeys.General.mainWindowSection)
    }

    @discardableResult
    static func focusExisting(_ destination: MainDestination) -> Bool {
        guard let entry = entries.first(where: { $0.controller.destination == destination })
        else { return false }
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    static let baseContentSize = NSSize(width: 880, height: 640)
    static let baseMinimumSize = NSSize(width: 560, height: 420)

    static func contains(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return entries.contains { $0.window === window }
    }

    static func resizeForZoom(from oldScale: Double, to newScale: Double) {
        guard oldScale > 0, abs(oldScale - newScale) > 0.000_1 else { return }
        for entry in entries {
            let window = entry.window
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let minimum = MainWindowFramePolicy.scaled(
                baseMinimumSize, by: newScale, visible: visible.size)
            window.contentMinSize = minimum
            guard !window.styleMask.contains(.fullScreen) else { continue }
            let content = window.contentRect(forFrameRect: window.frame)
            let size = MainWindowFramePolicy.zoomedContentSize(
                current: content.size, minimum: minimum, visible: visible.size, from: oldScale,
                to: newScale)
            let rect = MainWindowFramePolicy.centeredContentRect(
                current: content, size: size, visible: visible)
            window.setFrame(window.frameRect(forContentRect: rect), display: true)
        }
    }

    static func open(_ destination: MainDestination, mode: SectionOpenMode = .reuseMostRecent) {
        if focusExisting(destination) { return }
        makeWindow(destination, tabbedInto: mode == .reuseMostRecent ? entries.first?.window : nil)
    }

    private static func makeWindow(_ destination: MainDestination, tabbedInto host: NSWindow?) {
        let controller = SectionWindowController(destination: destination)
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = UIScale.current
        let size = MainWindowFramePolicy.scaled(baseContentSize, by: scale, visible: visible)
        let minimum = MainWindowFramePolicy.scaled(baseMinimumSize, by: scale, visible: visible)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = destination.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimum
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "EdithSection"
        let hosting = NSHostingController(
            rootView: ZoomableRoot { DetachedSectionView(controller: controller) })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.delegate = SectionWindowDelegate.shared
        entries.insert(Entry(window: window, controller: controller), at: 0)
        if let host, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
        } else {
            window.setFrameAutosaveName("EdithSectionWindow")
            if window.frame.origin == .zero { window.center() }
            offsetFromOverlappingWindows(window)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func offsetFromOverlappingWindows(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let occupied = NSApp.windows.filter { $0 !== window && $0.isVisible }.map(\.frame)
        var frame = window.frame
        if frame.size.width > screen.visibleFrame.width * 0.9 {
            frame.size = MainWindowFramePolicy.scaled(
                baseContentSize, by: UIScale.current, visible: screen.visibleFrame.size)
        }
        var attempts = 0
        while occupied.contains(where: { abs($0.origin.x - frame.origin.x) < 12 })
            && attempts < 8
        {
            frame.origin.x += 26
            frame.origin.y -= 26
            attempts += 1
        }
        if !screen.visibleFrame.contains(frame.origin) {
            frame.origin = NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.midY - frame.height / 2)
        }
        window.setFrame(frame, display: false)
    }

    static func noteBecameKey(_ window: NSWindow) {
        guard let index = entries.firstIndex(where: { $0.window === window }), index > 0 else {
            return
        }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
    }

    static func forget(_ window: NSWindow) {
        entries.removeAll { $0.window === window }
    }

    static func destination(of window: NSWindow) -> MainDestination? {
        entries.first { $0.window === window }?.controller.destination
    }

    static func title(of window: NSWindow) -> String? {
        entries.first { $0.window === window }?.controller.destination.title
    }
}

@MainActor
final class SectionWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SectionWindowDelegate()

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        SectionWindow.noteBecameKey(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        SectionWindow.forget(window)
        WindowTabs.clearHints()
    }
}

enum SectionWindowCommand {
    static func shouldDetach(_ modifiers: EventModifiers) -> Bool {
        modifiers.contains(.command)
    }

    static func detachableDestinations(visibleHomeItems: [MainDestination]) -> [MainDestination] {
        visibleHomeItems + [.extensions]
    }
}

@MainActor
enum WindowTabs {
    private static var baseTitles: [ObjectIdentifier: String] = [:]
    private static var hintsShown = false

    static func tabbedWindows(for window: NSWindow?) -> [NSWindow] {
        guard let group = window?.tabGroup, group.windows.count > 1 else { return [] }
        return group.windows
    }

    static func isTabbed(_ window: NSWindow?) -> Bool {
        !tabbedWindows(for: window).isEmpty
    }

    static func selectTab(index: Int, in window: NSWindow?) -> Bool {
        let windows = tabbedWindows(for: window)
        guard index >= 0, index < windows.count else { return false }
        windows[index].makeKeyAndOrderFront(nil)
        return true
    }

    static func selectNextTab(in window: NSWindow?, backwards: Bool) -> Bool {
        let windows = tabbedWindows(for: window)
        guard let window, let current = windows.firstIndex(of: window), !windows.isEmpty else {
            return false
        }
        let count = windows.count
        let next = backwards ? (current - 1 + count) % count : (current + 1) % count
        windows[next].makeKeyAndOrderFront(nil)
        return true
    }

    static func showHints(_ show: Bool) {
        guard show != hintsShown else { return }
        hintsShown = show
        let windows = tabbedWindows(for: NSApp.keyWindow)
        guard !windows.isEmpty else {
            if !show { clearHints() }
            return
        }
        for (index, window) in windows.enumerated() {
            let key = ObjectIdentifier(window)
            if show {
                if baseTitles[key] == nil { baseTitles[key] = window.title }
                guard index < 9, let base = baseTitles[key] else { continue }
                window.title = "⌘\(index + 1)  \(base)"
            } else if let base = baseTitles[key] {
                window.title = base
                baseTitles.removeValue(forKey: key)
            }
        }
    }

    static func clearHints() {
        for window in NSApp.windows {
            guard let base = baseTitles[ObjectIdentifier(window)] else { continue }
            window.title = base
        }
        baseTitles = [:]
        hintsShown = false
    }
}
