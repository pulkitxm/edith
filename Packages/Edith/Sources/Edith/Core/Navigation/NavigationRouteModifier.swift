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
    static let blockedClassFragments = [
        "GhosttyTerminalView", "EdithTerminalView", "LocalProcessTerminalView", "WKWebView",
        "NotchWebView", "SourceEditor", "CodeEditor",
    ]

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

    static func allowsHistory(classNames: [String], textRole: NavigationTextRole) -> Bool {
        if textRole == .editor { return false }
        for name in classNames where blockedClassFragments.contains(where: { name.contains($0) }) {
            return false
        }
        return true
    }

    static func textRole(of responder: NSResponder) -> NavigationTextRole {
        guard let text = responder as? NSTextView, text.isEditable else { return .none }
        return text.isFieldEditor ? .fieldEditor : .editor
    }

    static func allowsHistory(responder: NSResponder?) -> Bool {
        var names: [String] = []
        var role = NavigationTextRole.none
        var current = responder
        var seen: Set<ObjectIdentifier> = []
        while let view = current {
            let identity = ObjectIdentifier(view)
            if !seen.insert(identity).inserted { break }
            names.append(NSStringFromClass(type(of: view)))
            let nextRole = textRole(of: view)
            if nextRole == .editor { role = .editor }
            if let nested = view as? NSView, let superview = nested.superview {
                current = superview
            } else {
                current = view.nextResponder
            }
        }
        return allowsHistory(classNames: names, textRole: role)
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

extension EnvironmentValues {
    var windowRouter: WindowRouter? {
        get { self[WindowRouterKey.self] }
        set { self[WindowRouterKey.self] = newValue }
    }

    var navigationRouteDepth: Int {
        get { self[NavigationRouteDepthKey.self] }
        set { self[NavigationRouteDepthKey.self] = newValue }
    }
}

struct NavigationRouteHost<Content: View>: View {
    let router: WindowRouter
    var role: WindowRouter.Role = .auxiliary
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.windowRouter, router)
            .background { WindowRouterAnchor(router: router, role: role) }
    }
}

extension View {
    func navigationRoute<S: LosslessStringConvertible & Equatable>(
        _ name: String, selection: Binding<S>, isValid: ((S) -> Bool)? = nil
    ) -> some View {
        modifier(
            NavigationRouteModifier(
                name: name,
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
                }))
    }

    func navigationRoute<S: RawRepresentable & Equatable>(
        _ name: String, selection: Binding<S>, isValid: ((S) -> Bool)? = nil
    ) -> some View where S.RawValue: LosslessStringConvertible {
        modifier(
            NavigationRouteModifier(
                name: name,
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
                }))
    }

    func navigationRoute(
        _ name: String, selection: Binding<String?>, isValid: ((String) -> Bool)? = nil
    ) -> some View {
        navigationRoute(
            name,
            selection: Binding<String>(
                get: { selection.wrappedValue ?? "" },
                set: { selection.wrappedValue = $0.isEmpty ? nil : $0 }),
            isValid: { value in
                if value.isEmpty { return true }
                return isValid?(value) ?? true
            })
    }

    func navigationRoute(
        _ name: String, selection: Binding<UUID?>, isValid: ((UUID) -> Bool)? = nil
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
            })
    }
}

private struct NavigationRouteModifier: ViewModifier {
    let name: String
    @Binding var text: String
    let accept: (String) -> Bool
    @Environment(\.windowRouter) private var router
    @Environment(\.navigationRouteDepth) private var depth

    func body(content: Content) -> some View {
        content
            .environment(\.navigationRouteDepth, depth + 1)
            .background {
                RouteSlotAnchor(
                    depth: depth, name: name, value: text, accept: accept,
                    apply: { proposed in
                        if text != proposed { text = proposed }
                    })
            }
            .onDisappear {
                NavigationRouteMount.unregister(router: router, depth: depth, name: name)
            }
    }
}

struct RouteSlotAnchor: View {
    let depth: Int
    let name: String
    let value: String
    let accept: (String) -> Bool
    let apply: (String) -> Void
    var installedRouter: WindowRouter?
    @Environment(\.windowRouter) private var environmentRouter

    private var router: WindowRouter? { installedRouter ?? environmentRouter }

    var body: some View {
        let _ = NavigationRouteMount.sync(
            router: router, depth: depth, name: name, value: value, accept: accept, apply: apply)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .background {
                RouteSlotRepresentable(
                    router: router, depth: depth, name: name, value: value, accept: accept,
                    apply: apply)
            }
    }

    func unmount() {
        NavigationRouteMount.unregister(router: router, depth: depth, name: name)
    }
}

enum NavigationRouteMount {
    @MainActor
    static func sync(
        router: WindowRouter?, depth: Int, name: String, value: String,
        accept: @escaping (String) -> Bool, apply: @escaping (String) -> Void
    ) {
        router?.sync(depth: depth, name: name, value: value, accept: accept, apply: apply)
    }

    @MainActor
    static func unregister(router: WindowRouter?, depth: Int, name: String) {
        router?.unregister(depth: depth, name: name)
    }
}

private struct RouteSlotRepresentable: NSViewRepresentable {
    let router: WindowRouter?
    let depth: Int
    let name: String
    let value: String
    let accept: (String) -> Bool
    let apply: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.router = router
        context.coordinator.depth = depth
        context.coordinator.name = name
        router?.sync(depth: depth, name: name, value: value, accept: accept, apply: apply)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        NavigationRouteMount.unregister(
            router: coordinator.router, depth: coordinator.depth, name: coordinator.name)
    }

    final class Coordinator {
        var router: WindowRouter?
        var depth = 0
        var name = ""
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
        guard let router = WindowRouter.forKeyWindow() else { return false }
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
        if event.type == .keyDown, NavigationShortcutGate.direction(for: event) != nil {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class NavigationMenuTarget: NSObject, NSMenuDelegate {
    static let shared = NavigationMenuTarget()

    @objc func goBack(_ sender: Any?) {
        WindowRouter.forKeyWindow()?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        WindowRouter.forKeyWindow()?.goForward()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let router = WindowRouter.forKeyWindow()
        for item in menu.items {
            if item.action == #selector(goBack(_:)) { item.isEnabled = router?.canGoBack == true }
            if item.action == #selector(goForward(_:)) {
                item.isEnabled = router?.canGoForward == true
            }
        }
    }
}
