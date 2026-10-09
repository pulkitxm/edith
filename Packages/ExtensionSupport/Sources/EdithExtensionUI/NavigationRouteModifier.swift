import AppKit
import SwiftUI

enum NavigationDirection: Equatable {
    case back
    case forward
}

enum NavigationTextRole: Equatable {
    case none
    case fieldEditor
    case editor
}

enum NavigationShortcutGate {
    static func direction(keyCharacter: String?, modifiers: NSEvent.ModifierFlags)
        -> NavigationDirection?
    {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([
            .capsLock, .function, .numericPad,
        ])
        guard flags == .command else { return nil }
        switch keyCharacter {
        case "[": return .back
        case "]": return .forward
        default: return nil
        }
    }

    static func direction(buttonNumber: Int) -> NavigationDirection? {
        switch buttonNumber {
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    static func direction(for event: NSEvent) -> NavigationDirection? {
        switch event.type {
        case .keyDown:
            return direction(
                keyCharacter: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
        case .otherMouseDown:
            return direction(buttonNumber: event.buttonNumber)
        default:
            return nil
        }
    }

    static func textRole(of responder: NSResponder) -> NavigationTextRole {
        guard let text = responder as? NSTextView, text.isEditable else { return .none }
        return text.isFieldEditor ? .fieldEditor : .editor
    }

    static func allowsHistory(responder: NSResponder?) -> Bool {
        var role = NavigationTextRole.none
        var current = responder
        var seen: Set<ObjectIdentifier> = []
        while let view = current {
            let identity = ObjectIdentifier(view)
            if !seen.insert(identity).inserted { break }
            let nextRole = textRole(of: view)
            if nextRole == .editor { role = .editor }
            if let nested = view as? NSView, let superview = nested.superview {
                current = superview
            } else {
                current = view.nextResponder
            }
        }
        return role != .editor
    }

    static func allowsMouseHistory(_ event: NSEvent) -> Bool {
        guard direction(buttonNumber: event.buttonNumber) != nil else { return false }
        if !allowsHistory(responder: event.window?.firstResponder) { return false }
        if let hit = event.window?.contentView?.hitTest(event.locationInWindow),
            !allowsHistory(responder: hit)
        {
            return false
        }
        return true
    }
}

private struct WindowRouterKey: EnvironmentKey {
    static let defaultValue: WindowRouter? = nil
}

private struct NavigationRouteDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct NavigationRouteScopeKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension EnvironmentValues {
    var windowRouter: WindowRouter? {
        get { self[WindowRouterKey.self] }
        set { self[WindowRouterKey.self] = newValue }
    }

    var navigationRouteDepth: Int {
        get { self[NavigationRouteDepthKey.self] }
        set { self[NavigationRouteDepthKey.self] = newValue }
    }

    var navigationRouteScope: [String] {
        get { self[NavigationRouteScopeKey.self] }
        set { self[NavigationRouteScopeKey.self] = newValue }
    }
}

public struct NavigationRouteHost<Content: View>: View {
    let router: WindowRouter
    var role: WindowRouter.Role = .auxiliary
    @ViewBuilder var content: Content

    public init(
        router: WindowRouter, role: WindowRouter.Role = .auxiliary,
        @ViewBuilder content: () -> Content
    ) {
        self.router = router
        self.role = role
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.windowRouter, router)
            .background { WindowRouterAnchor(router: router, role: role) }
    }
}

extension View {
    public func navigationRoute<S: LosslessStringConvertible & Equatable>(
        _ name: String, selection: Binding<S>, isValid: ((S) -> Bool)? = nil,
        isReady: @escaping @MainActor () async -> Void
    ) -> some View {
        NavigationRouteReadiness(load: isReady) { ready in
            navigationRoute(name, selection: selection, isValid: isValid, isReady: ready)
        }
    }

    public func navigationRoute<S: LosslessStringConvertible & Equatable>(
        _ name: String, selection: Binding<S>, isValid: ((S) -> Bool)? = nil, isReady: Bool = true
    ) -> some View {
        NavigationRouteSlot(
            name: name,
            ready: isReady,
            text: Binding(
                get: { selection.wrappedValue.description },
                set: { proposed in
                    guard let value = S(proposed) else { return }
                    selection.wrappedValue = value
                }),
            accept: { raw in
                if raw.isEmpty { return true }
                guard let value = S(raw) else { return false }
                return isValid?(value) ?? true
            },
            content: self)
    }

    public func navigationRoute<S: RawRepresentable & Equatable>(
        _ name: String, selection: Binding<S>, isValid: ((S) -> Bool)? = nil, isReady: Bool = true
    ) -> some View where S.RawValue: LosslessStringConvertible {
        NavigationRouteSlot(
            name: name,
            ready: isReady,
            text: Binding(
                get: { selection.wrappedValue.rawValue.description },
                set: { proposed in
                    guard let raw = S.RawValue(proposed), let value = S(rawValue: raw) else {
                        return
                    }
                    selection.wrappedValue = value
                }),
            accept: { raw in
                if raw.isEmpty { return true }
                guard let rawValue = S.RawValue(raw), let value = S(rawValue: rawValue) else {
                    return false
                }
                return isValid?(value) ?? true
            },
            content: self)
    }

    public func navigationRoute(
        _ name: String, selection: Binding<String?>, isValid: ((String) -> Bool)? = nil,
        isReady: Bool = true
    ) -> some View {
        navigationRoute(
            name,
            selection: Binding<String>(
                get: { selection.wrappedValue ?? "" },
                set: { selection.wrappedValue = $0.isEmpty ? nil : $0 }),
            isValid: { value in
                if value.isEmpty { return true }
                return isValid?(value) ?? true
            }, isReady: isReady)
    }

    public func navigationRoute(
        _ name: String, selection: Binding<UUID?>, isValid: ((UUID) -> Bool)? = nil,
        isReady: Bool = true
    ) -> some View {
        navigationRoute(
            name,
            selection: Binding<String>(
                get: { selection.wrappedValue?.uuidString ?? "" },
                set: { proposed in
                    if proposed.isEmpty {
                        selection.wrappedValue = nil
                    } else if let id = UUID(uuidString: proposed) {
                        selection.wrappedValue = id
                    }
                }),
            isValid: { raw in
                if raw.isEmpty { return true }
                guard let id = UUID(uuidString: raw) else { return false }
                return isValid?(id) ?? true
            }, isReady: isReady)
    }
}

private struct NavigationRouteReadiness<Content: View>: View {
    let load: @MainActor () async -> Void
    @ViewBuilder var content: (Bool) -> Content
    @State private var ready = false

    var body: some View {
        content(ready)
            .task {
                await load()
                guard !Task.isCancelled else { return }
                ready = true
            }
    }
}

private struct NavigationRouteSlot<Content: View>: View {
    let name: String
    let ready: Bool
    @State private var owner = UUID()
    @Binding var text: String
    let accept: (String) -> Bool
    let content: Content
    @Environment(\.windowRouter) private var router
    @Environment(\.navigationRouteDepth) private var depth
    @Environment(\.navigationRouteScope) private var scope

    var body: some View {
        content
            .background {
                RouteSlotAnchor(
                    depth: depth, name: name, value: text, owner: owner, ready: ready,
                    scope: scope,
                    accept: accept,
                    apply: applyProposed, installedRouter: router)
            }
            .environment(\.navigationRouteDepth, depth + 1)
            .environment(\.navigationRouteScope, scope + [text])
    }

    private func applyProposed(_ proposed: String) {
        if text != proposed { text = proposed }
    }
}

struct RouteSlotAnchor: View {
    let depth: Int
    let name: String
    let value: String
    var owner: UUID? = nil
    var ready = true
    var scope: [String] = []
    let accept: (String) -> Bool
    let apply: (String) -> Void
    var installedRouter: WindowRouter?
    @Environment(\.windowRouter) private var environmentRouter

    private var router: WindowRouter? { installedRouter ?? environmentRouter }

    var body: some View {
        Color.clear
            .frame(width: UIScale.pt(0), height: UIScale.pt(0))
            .accessibilityHidden(true)
            .background {
                RouteSlotRepresentable(
                    router: router, depth: depth, name: name, value: value, owner: owner,
                    ready: ready, scope: scope, accept: accept,
                    apply: apply)
            }
    }

    func unmount() {
        NavigationRouteMount.unregister(router: router, depth: depth, name: name, owner: owner)
    }
}

enum NavigationRouteMount {
    @MainActor
    static func sync(
        router: WindowRouter?, depth: Int, name: String, value: String, owner: UUID? = nil,
        ready: Bool = true,
        accept: @escaping (String) -> Bool, apply: @escaping (String) -> Void
    ) {
        router?.sync(
            depth: depth, name: name, value: value, owner: owner, ready: ready, accept: accept,
            apply: apply)
    }

    @MainActor
    static func unregister(router: WindowRouter?, depth: Int, name: String, owner: UUID? = nil) {
        router?.unregister(depth: depth, name: name, owner: owner)
    }
}

private struct RouteSlotRepresentable: NSViewRepresentable {
    let router: WindowRouter?
    let depth: Int
    let name: String
    let value: String
    let owner: UUID?
    let ready: Bool
    let scope: [String]
    let accept: (String) -> Bool
    let apply: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SlotView {
        let view = SlotView(frame: .zero)
        view.isHidden = true
        view.onMove = { [weak view] in
            guard let view else { return }
            context.coordinator.schedulePublish(in: view)
        }
        return view
    }

    func updateNSView(_ view: SlotView, context: Context) {
        context.coordinator.router = router
        context.coordinator.depth = depth
        context.coordinator.name = name
        context.coordinator.value = value
        context.coordinator.owner = owner
        context.coordinator.slotReady = ready
        context.coordinator.scope = scope
        context.coordinator.accept = accept
        context.coordinator.apply = apply
        context.coordinator.ready = true
        context.coordinator.schedulePublish(in: view)
    }

    static func dismantleNSView(_ view: SlotView, coordinator: Coordinator) {
        view.onMove = nil
        coordinator.cancel()
        NavigationRouteMount.unregister(
            router: coordinator.resolved ?? coordinator.router, depth: coordinator.depth,
            name: coordinator.name, owner: coordinator.owner)
    }

    final class Coordinator {
        var router: WindowRouter?
        var depth = 0
        var name = ""
        var value = ""
        var owner: UUID?
        var slotReady = true
        var scope: [String] = []
        var accept: (String) -> Bool = { _ in true }
        var apply: (String) -> Void = { _ in }
        var resolved: WindowRouter?
        var ready = false
        private var retry: DispatchWorkItem?
        private var attempts = 0

        func cancel() {
            retry?.cancel()
            retry = nil
        }

        func schedulePublish(in view: NSView) {
            cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                self.retry = nil
                self.publish(in: view)
            }
            retry = work
            DispatchQueue.main.async(execute: work)
        }

        func publish(in view: NSView) {
            guard ready else { return }
            let preferred = router
            let found = MainActor.assumeIsolated { () -> WindowRouter? in
                if let preferred { return preferred }
                guard let window = view.window else { return nil }
                return WindowRouter.router(for: window)
            }
            guard let found else {
                guard attempts < 2, retry == nil else { return }
                attempts += 1
                let work = DispatchWorkItem { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.retry = nil
                    self.publish(in: view)
                }
                retry = work
                DispatchQueue.main.async(execute: work)
                return
            }
            cancel()
            resolved = found
            let slotDepth = depth
            let slotName = name
            let slotValue = value
            let slotOwner = owner
            let isSlotReady = slotReady
            let slotScope = scope
            let slotAccept = accept
            let slotApply = apply
            MainActor.assumeIsolated {
                found.sync(
                    depth: slotDepth, name: slotName, value: slotValue, owner: slotOwner,
                    ready: isSlotReady, scope: slotScope, accept: slotAccept,
                    apply: slotApply)
            }
        }
    }

    final class SlotView: NSView {
        var onMove: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMove?()
        }
    }
}

private struct WindowRouterAnchor: NSViewRepresentable {
    let router: WindowRouter
    let role: WindowRouter.Role

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.router = router
        view.role = role
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.router = router
        view.role = role
        view.sync()
    }

    final class AnchorView: NSView {
        var router: WindowRouter?
        var role = WindowRouter.Role.auxiliary

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { router?.detach() }
            sync()
        }

        func sync() {
            guard let router, let window else { return }
            router.attach(window, role: role)
            NavigationHistoryInput.install()
        }
    }
}

@MainActor
enum NavigationHistoryInput {
    private static var monitor: Any?
    private static var installedMenu = false

    static func install() {
        installMonitor()
        installMenu()
    }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            let handled = MainActor.assumeIsolated { handle(event) }
            return handled ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard let direction = NavigationShortcutGate.direction(for: event) else { return false }
        if event.type == .keyDown {
            guard NavigationShortcutGate.allowsHistory(responder: NSApp.keyWindow?.firstResponder)
            else { return false }
        } else {
            guard NavigationShortcutGate.allowsMouseHistory(event) else { return false }
        }
        guard let router = WindowRouter.router(for: event.window ?? NSApp.keyWindow),
            (direction == .back ? router.canGoBack : router.canGoForward)
        else { return false }
        switch direction {
        case .back: router.goBack()
        case .forward: router.goForward()
        }
        return true
    }

    private static func installMenu() {
        guard !installedMenu, let main = NSApp.mainMenu else { return }
        if main.items.contains(where: { $0.submenu is NavigationMenu }) {
            installedMenu = true
            return
        }
        let menu = NavigationMenu(title: "Navigate")
        let back = NSMenuItem(
            title: "Back", action: #selector(NavigationMenuTarget.goBack(_:)), keyEquivalent: "[")
        back.keyEquivalentModifierMask = .command
        back.target = NavigationMenuTarget.shared
        let forward = NSMenuItem(
            title: "Forward", action: #selector(NavigationMenuTarget.goForward(_:)),
            keyEquivalent: "]")
        forward.keyEquivalentModifierMask = .command
        forward.target = NavigationMenuTarget.shared
        menu.addItem(back)
        menu.addItem(forward)
        menu.delegate = NavigationMenuTarget.shared
        let item = NSMenuItem(title: "Navigate", action: nil, keyEquivalent: "")
        item.submenu = menu
        if let index = main.items.firstIndex(where: { $0.title == "Window" }) {
            main.insertItem(item, at: index)
        } else {
            main.addItem(item)
        }
        installedMenu = true
    }
}

private final class NavigationMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !NavigationShortcutGate.allowsHistory(responder: NSApp.keyWindow?.firstResponder) {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class NavigationMenuTarget: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = NavigationMenuTarget()

    @objc func goBack(_ sender: Any?) {
        WindowRouter.forKeyWindow()?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        WindowRouter.forKeyWindow()?.goForward()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            item.isEnabled = validateMenuItem(item)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard NavigationShortcutGate.allowsHistory(responder: NSApp.keyWindow?.firstResponder),
            let router = WindowRouter.forKeyWindow()
        else { return false }
        return item.action == #selector(goBack(_:)) ? router.canGoBack : router.canGoForward
    }
}
