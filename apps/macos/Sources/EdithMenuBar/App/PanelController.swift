import AppKit
import EdithKit
import SwiftUI

@MainActor
final class PanelController: NSObject {
    static var shared: PanelController?

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let services: AppServices
    private var eventMonitor: Any?
    private var keyMonitor: Any?

    var isOpen: Bool { popover.isShown }
    var statusItemFrame: NSRect? { statusItem.button?.window?.frame }

    init(services: AppServices) {
        self.services = services
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "edithGlasses"
        statusItem.isVisible = false
        super.init()

        popover.behavior = .transient
        popover.animates = true
    }

    func toggle() {
        MainApp.openDashboard()
    }

    func open() {
        guard !popover.isShown, let button = statusItem.button else { return }
        let host = NSHostingController(
            rootView: AnyView(RootView().environmentObject(services)))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            window.makeFirstResponder(window.contentView)
        }
        startEventMonitor()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
        popover.contentViewController = nil
        stopEventMonitor()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let mods = event.modifierFlags
            let handled = MainActor.assumeIsolated { self?.handleMusicKey(code: code, mods: mods) }
            return (handled ?? false) ? nil : event
        }
    }

    private func handleMusicKey(code: UInt16, mods: NSEvent.ModifierFlags) -> Bool {
        guard let music = services.music else { return false }
        return MusicKeyCommand.handle(
            keyCode: code, modifiers: mods, active: music.current != nil,
            .init(
                playPause: { music.playPause() },
                seekBy: { seconds in
                    let duration = music.trackDuration
                    guard duration > 0 else { return }
                    let target = min(max(music.elapsed + seconds, 0), duration)
                    music.seek(to: target / duration)
                },
                volumeBy: { delta in music.volume = min(max(music.volume + delta, 0), 1) }))
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

enum AppState {
    @MainActor static let services = migratedServices()
}
