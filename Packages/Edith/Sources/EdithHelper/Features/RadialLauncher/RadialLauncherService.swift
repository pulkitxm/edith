import AppKit
import Carbon.HIToolbox
import CoreGraphics
import EdithKit
import IOKit.hidsystem
import SwiftUI

@MainActor
final class RadialLauncherService: ObservableObject {
    @Published private(set) var profile = RadialLauncherProfile.starter
    @Published private(set) var highlightedIndex: Int?
    @Published private(set) var visible = false

    private let executeEdith: (RadialLauncherEdithAction) -> Void
    private var panel: RadialLauncherPanel?
    private var monitors: [Any] = []
    private var requestObserver: NSObjectProtocol?
    private var center = CGPoint.zero

    var items: [RadialLauncherItem] {
        profile.items.filter(\.isConfigured)
    }

    init(executeEdith: @escaping (RadialLauncherEdithAction) -> Void) {
        self.executeEdith = executeEdith
        requestObserver = IPC.observe(IPC.Name.requestRadialLauncher) { [weak self] in
            self?.show()
        }
        syncSettings()
    }

    func syncSettings() {
        profile = RadialLauncherProfileStore.decode(
            SharedDefaults.store.string(forKey: RadialLauncherPreferenceKeys.profile))
        guard SharedDefaults.store.bool(forKey: RadialLauncherPreferenceKeys.enabled) else {
            shutdownRuntime()
            return
        }
        let code =
            SharedDefaults.store.object(
                forKey: RadialLauncherPreferenceKeys.hotKeyCode) as? Int ?? kVK_Space
        let modifiers =
            SharedDefaults.store.object(
                forKey: RadialLauncherPreferenceKeys.hotKeyMods) as? Int ?? (cmdKey | optionKey)
        GlobalHotKey.set(
            id: GlobalHotKey.ID.radialLauncher, keyCode: code, modifiers: modifiers,
            action: { [weak self] in self?.show() },
            release: { [weak self] in self?.shortcutReleased() })
    }

    func shutdown() {
        shutdownRuntime()
        if let requestObserver { IPC.stopObserving(requestObserver) }
        requestObserver = nil
    }

    func show() {
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        if visible {
            dismiss()
            return
        }
        highlightedIndex = nil
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return }
        let usePointer =
            SharedDefaults.store.object(
                forKey: RadialLauncherPreferenceKeys.atPointer) as? Bool ?? true
        let wanted =
            usePointer
            ? pointer : CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        center = clamped(wanted, to: screen.visibleFrame)
        let panel = ensurePanel()
        let size = RadialLauncherLayout.panelSize
        panel.setFrame(
            NSRect(
                x: center.x - size / 2, y: center.y - size / 2,
                width: size, height: size),
            display: true)
        visible = true
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
    }

    func dismiss() {
        visible = false
        highlightedIndex = nil
        panel?.orderOut(nil)
        removeMonitors()
    }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        dismiss()
        execute(item)
    }

    private func shortcutReleased() {
        guard visible, let highlightedIndex else { return }
        select(highlightedIndex)
    }

    private func ensurePanel() -> RadialLauncherPanel {
        if let panel { return panel }
        let panel = RadialLauncherPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: RadialLauncherWheel(service: self))
        self.panel = panel
        return panel
    }

    private func installMonitors() {
        removeMonitors()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: events,
            handler: { [weak self] event in
                self?.updateHighlight(NSEvent.mouseLocation)
                return event
            })
        {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: events,
            handler: { [weak self] _ in
                let point = NSEvent.mouseLocation
                Task { @MainActor in self?.updateHighlight(point) }
            })
        {
            monitors.append(global)
        }
        if let mouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                let point = NSEvent.mouseLocation
                Task { @MainActor in
                    guard self?.panel?.frame.contains(point) == false else { return }
                    self?.dismiss()
                }
            })
        {
            monitors.append(mouse)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                let keyCode = event.keyCode
                let characters = event.charactersIgnoringModifiers
                let handled = MainActor.assumeIsolated {
                    self?.handleKey(keyCode: keyCode, characters: characters) == true
                }
                return handled ? nil : event
            })
        {
            monitors.append(keys)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleKey(keyCode: UInt16, characters: String?) -> Bool {
        if keyCode == 53 {
            dismiss()
            return true
        }
        if keyCode == 36, let highlightedIndex {
            select(highlightedIndex)
            return true
        }
        if let digit = Int(characters ?? ""),
            digit > 0, items.indices.contains(digit - 1)
        {
            select(digit - 1)
            return true
        }
        if keyCode == 123 || keyCode == 126 {
            moveSelection(-1)
            return true
        }
        if keyCode == 124 || keyCode == 125 {
            moveSelection(1)
            return true
        }
        return false
    }

    private func moveSelection(_ amount: Int) {
        let count = items.count
        guard count > 0 else { return }
        highlightedIndex = ((highlightedIndex ?? (amount > 0 ? -1 : 0)) + amount + count) % count
    }

    private func updateHighlight(_ point: CGPoint) {
        highlightedIndex = RadialLauncherSelection.index(
            dx: point.x - center.x, dy: point.y - center.y,
            itemCount: items.count, deadZone: RadialLauncherLayout.deadZone)
    }

    private func clamped(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        let inset = RadialLauncherLayout.panelSize / 2
        return CGPoint(
            x: min(max(point.x, frame.minX + inset), frame.maxX - inset),
            y: min(max(point.y, frame.minY + inset), frame.maxY - inset))
    }

    private func execute(_ item: RadialLauncherItem) {
        switch item.kind {
        case .application, .file:
            let path = NSString(string: item.payload).expandingTildeInPath
            guard !path.isEmpty else { return NSSound.beep() }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .link:
            guard let url = URL(string: item.payload),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return NSSound.beep() }
            NSWorkspace.shared.open(url)
        case .keyCombination:
            postKey(code: item.keyCode, modifiers: item.modifiers)
        case .media:
            guard let action = RadialLauncherMediaAction(rawValue: item.payload) else {
                return NSSound.beep()
            }
            postMedia(action)
        case .edith:
            guard let action = RadialLauncherEdithAction(rawValue: item.payload) else {
                return NSSound.beep()
            }
            executeEdith(action)
        }
    }

    private func postKey(code: Int, modifiers: Int) {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            IPC.post(IPC.Name.permissionHintDue)
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
            let up = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
        else { return }
        var flags = CGEventFlags()
        if modifiers & cmdKey != 0 { flags.insert(.maskCommand) }
        if modifiers & optionKey != 0 { flags.insert(.maskAlternate) }
        if modifiers & controlKey != 0 { flags.insert(.maskControl) }
        if modifiers & shiftKey != 0 { flags.insert(.maskShift) }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postMedia(_ action: RadialLauncherMediaAction) {
        let key: Int32
        switch action {
        case .playPause: key = NX_KEYTYPE_PLAY
        case .next: key = NX_KEYTYPE_NEXT
        case .previous: key = NX_KEYTYPE_PREVIOUS
        }
        for state in [0xA, 0xB] {
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8,
                data1: Int((key << 16) | Int32(state << 8)), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func shutdownRuntime() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.radialLauncher)
        dismiss()
        panel?.contentView = nil
        panel = nil
    }
}

private final class RadialLauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private enum RadialLauncherLayout {
    static let panelSize: CGFloat = 440
    static let radius: CGFloat = 145
    static let deadZone: CGFloat = 46
}

private struct RadialLauncherWheel: View {
    @ObservedObject var service: RadialLauncherService

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 350, height: 350)
                .overlay(Circle().stroke(.white.opacity(0.16)))
                .shadow(color: .black.opacity(0.3), radius: 28, y: 12)
            ForEach(Array(service.items.enumerated()), id: \.element.id) { index, item in
                itemButton(item, index: index)
                    .offset(offset(index, count: service.items.count))
            }
            VStack(spacing: 4) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 25, weight: .semibold))
                Text(service.profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("esc to close")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 104, height: 104)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.12)))
        }
        .frame(width: RadialLauncherLayout.panelSize, height: RadialLauncherLayout.panelSize)
    }

    private func itemButton(_ item: RadialLauncherItem, index: Int) -> some View {
        Button {
            service.select(index)
        } label: {
            VStack(spacing: 6) {
                itemIcon(item)
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 30, height: 30)
                Text(item.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(service.highlightedIndex == index ? Color.white : Color.primary)
            .frame(width: 86, height: 86)
            .background(
                service.highlightedIndex == index ? Color.accentColor : Color.clear,
                in: Circle()
            )
            .background(.regularMaterial, in: Circle())
            .overlay(
                Circle().stroke(.white.opacity(service.highlightedIndex == index ? 0.5 : 0.12))
            )
            .scaleEffect(service.highlightedIndex == index ? 1.1 : 1)
            .shadow(
                color: service.highlightedIndex == index
                    ? Color.accentColor.opacity(0.45) : .black.opacity(0.18),
                radius: service.highlightedIndex == index ? 15 : 7, y: 4
            )
            .animation(.snappy(duration: 0.16), value: service.highlightedIndex)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(index + 1), \(item.displayName)")
    }

    @ViewBuilder
    private func itemIcon(_ item: RadialLauncherItem) -> some View {
        if item.kind == .application || item.kind == .file {
            let path = NSString(string: item.payload).expandingTildeInPath
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: item.effectiveSymbol)
        }
    }

    private func offset(_ index: Int, count: Int) -> CGSize {
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(count)
        return CGSize(
            width: cos(angle) * RadialLauncherLayout.radius,
            height: sin(angle) * RadialLauncherLayout.radius)
    }
}
