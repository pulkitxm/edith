import AppKit
import EdithKit
import SwiftUI

private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 680
    static let height: CGFloat = 470
    static let willShow = Notification.Name("commandBarWillShow")

    private let model: CommandBarModel
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    init(services: AppServices) {
        model = CommandBarModel(services: services)
        super.init()
        model.dismiss = { [weak self] in self?.hide() }
        model.shortcutsChanged = { [weak self] in
            guard let self else { return }
            CommandBarResultHotKeys.sync(controller: self)
        }
        makePanel()
        CommandBarResultHotKeys.sync(controller: self)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard let panel else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        ClipboardPanel.shared.hide()
        dismissPanel()
        model.prepare(frontmostPID: frontmostPID)
        NotificationCenter.default.post(name: Self.willShow, object: nil)
        panel.setFrameOrigin(origin(for: panel.frame.size))
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(hosting)
    }

    func hide() {
        model.close()
        panel?.orderOut(nil)
    }

    func syncSettings() {
        CommandBarHotKey.register()
        CommandBarResultHotKeys.sync(controller: self)
        if isVisible { model.prepare() }
    }

    func shutdown() {
        CommandBarHotKey.unregister()
        CommandBarResultHotKeys.clear()
        hide()
        model.shutdown()
        panel?.delegate = nil
        panel?.contentView = nil
        hosting = nil
        panel = nil
    }

    func executeShortcut(id: String) {
        model.executeShortcut(id: id)
    }

    private func makePanel() {
        let created = CommandBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .statusBar
        created.collectionBehavior = [
            .auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary,
        ]
        created.animationBehavior = .none
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 15
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: AnyView(CommandBarView(model: model)))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        created.contentView = effect
        hosting = host
        panel = created
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - min(120, frame.height * 0.16))
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.hide() }
    }
}
