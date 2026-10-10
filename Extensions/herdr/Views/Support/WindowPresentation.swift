import AppKit
import EdithExtensionSupport

@MainActor
public enum WindowPresentation {
    public static func makeKeyAndOrderFront(
        _ window: NSWindow,
        suppressed: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            != nil,
        perform: ((NSWindow) -> Void)? = nil
    ) {
        guard !suppressed else { return }
        if let perform {
            perform(window)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    public static func orderFront(
        _ window: NSWindow,
        suppressed: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            != nil,
        perform: ((NSWindow) -> Void)? = nil
    ) {
        guard !suppressed else { return }
        if let perform {
            perform(window)
        } else {
            window.orderFront(nil)
        }
    }

    public static func orderFrontRegardless(
        _ window: NSWindow?,
        makeKey: Bool = false,
        suppressed: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            != nil,
        perform: ((NSWindow) -> Void)? = nil
    ) {
        guard let window, !suppressed else { return }
        if let perform {
            perform(window)
            return
        }
        window.orderFrontRegardless()
        if makeKey { window.makeKey() }
    }

    public static func orderBelow(
        _ window: NSWindow, windowNumber: Int,
        suppressed: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            != nil
    ) {
        guard !suppressed else { return }
        window.order(.below, relativeTo: windowNumber)
    }

    public static func makeKey(
        _ window: NSWindow?,
        suppressed: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            != nil
    ) {
        guard let window, !suppressed else { return }
        window.makeKey()
    }

    public static func activate(
        ignoringOtherApps: Bool = true,
        suppressed: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            != nil,
        perform: (() -> Void)? = nil
    ) {
        guard !suppressed else { return }
        if let perform {
            perform()
        } else if ignoringOtherApps {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate()
        }
    }

    public static func present(_ window: NSWindow) {
        makeKeyAndOrderFront(window)
        activate()
    }

    public static func runModal(
        _ alert: NSAlert,
        suppressed: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            != nil
    ) -> NSApplication.ModalResponse {
        guard !suppressed else { return .abort }
        return alert.runModal()
    }

    public static func beginSheet(
        _ alert: NSAlert, on window: NSWindow,
        suppressed: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            != nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard !suppressed else {
            completion(.abort)
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    public static func pngData(of view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        markDisplay(view)
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func markDisplay(_ view: NSView) {
        for child in view.subviews { markDisplay(child) }
        view.needsDisplay = true
        view.displayIfNeeded()
    }
}

@MainActor
public enum AppLaunchConfiguration {
    public static func make() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil else {
            return configuration
        }
        configuration.activates = false
        configuration.hides = true
        var environment = ProcessInfo.processInfo.environment
        environment["EDITH_EXTENSION_FIXTURE_HOME"] =
            ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
        configuration.environment = environment
        return configuration
    }
}
