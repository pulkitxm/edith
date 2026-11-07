import AppKit
import EdithIcons
import ObjectiveC
import SwiftUI

public struct EdithMenuItem {
    public enum Content {
        case action(@MainActor () -> Void)
        case submenu([EdithMenuItem])
        case separator
    }

    public let title: String
    public let content: Content
    public let enabled: Bool
    public let help: String?

    public init(title: String, content: Content, enabled: Bool = true, help: String? = nil) {
        self.title = title
        self.content = content
        self.enabled = enabled
        self.help = help
    }

    public static func button(
        _ title: String, enabled: Bool = true, help: String? = nil,
        action: @escaping @MainActor () -> Void
    ) -> EdithMenuItem {
        EdithMenuItem(title: title, content: .action(action), enabled: enabled, help: help)
    }

    public static func menu(
        _ title: String, enabled: Bool = true, @EdithMenuBuilder items: () -> [EdithMenuItem]
    ) -> EdithMenuItem {
        EdithMenuItem(title: title, content: .submenu(items()), enabled: enabled)
    }

    public static var separator: EdithMenuItem {
        EdithMenuItem(title: "", content: .separator)
    }

    public var isSeparator: Bool {
        if case .separator = content { return true }
        return false
    }

    public func disabled(_ disabled: Bool) -> EdithMenuItem {
        EdithMenuItem(title: title, content: content, enabled: enabled && !disabled, help: help)
    }
}

extension Array where Element == EdithMenuItem {
    public func disabled(_ disabled: Bool) -> [EdithMenuItem] {
        map { $0.disabled(disabled) }
    }
}

@resultBuilder
public enum EdithMenuBuilder {
    public static func buildExpression(_ item: EdithMenuItem) -> [EdithMenuItem] { [item] }
    public static func buildExpression(_ items: [EdithMenuItem]) -> [EdithMenuItem] { items }
    public static func buildBlock(_ parts: [EdithMenuItem]...) -> [EdithMenuItem] {
        parts.flatMap { $0 }
    }
    public static func buildOptional(_ part: [EdithMenuItem]?) -> [EdithMenuItem] { part ?? [] }
    public static func buildEither(first part: [EdithMenuItem]) -> [EdithMenuItem] { part }
    public static func buildEither(second part: [EdithMenuItem]) -> [EdithMenuItem] { part }
    public static func buildArray(_ parts: [[EdithMenuItem]]) -> [EdithMenuItem] {
        parts.flatMap { $0 }
    }
    public static func buildLimitedAvailability(_ part: [EdithMenuItem]) -> [EdithMenuItem] {
        part
    }
}

public enum EdithMenu {
    public static func items(@EdithMenuBuilder _ items: () -> [EdithMenuItem]) -> [EdithMenuItem] {
        items()
    }

    public static func normalized(_ items: [EdithMenuItem]) -> [EdithMenuItem] {
        var result: [EdithMenuItem] = []
        for item in items {
            switch item.content {
            case .separator:
                if let last = result.last, !last.isSeparator { result.append(item) }
            case let .submenu(children):
                let kept = normalized(children)
                guard !kept.isEmpty else { continue }
                result.append(
                    EdithMenuItem(
                        title: item.title, content: .submenu(kept), enabled: item.enabled,
                        help: item.help))
            case .action:
                result.append(item)
            }
        }
        if result.last?.isSeparator == true { result.removeLast() }
        return result
    }

    @MainActor
    public static func makeMenu(_ items: [EdithMenuItem], title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in normalized(items) { menu.addItem(makeItem(item)) }
        return menu
    }

    @MainActor
    private static func makeItem(_ item: EdithMenuItem) -> NSMenuItem {
        let made: NSMenuItem
        switch item.content {
        case .separator:
            return .separator()
        case let .action(action):
            made = EdithMenuActionItem(title: item.title, handler: action)
        case let .submenu(children):
            made = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            made.submenu = makeMenu(children, title: item.title)
        }
        made.isEnabled = item.enabled
        made.toolTip = item.help
        return made
    }
}

final class EdithMenuActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        handler = {}
        super.init(coder: coder)
    }

    @objc(edithRunAction:) func runAction(_ sender: Any?) {
        MainActor.assumeIsolated { handler() }
    }
}

extension View {
    public func edithContextMenu(
        _ items: @escaping @MainActor () -> [EdithMenuItem]
    ) -> some View {
        overlay(EdithContextMenuRegion(items: items).accessibilityHidden(true))
    }
}

struct EdithContextMenuRegion: NSViewRepresentable {
    let items: @MainActor () -> [EdithMenuItem]

    func makeNSView(context: Context) -> EdithContextMenuView {
        let view = EdithContextMenuView()
        view.items = items
        return view
    }

    func updateNSView(_ view: EdithContextMenuView, context: Context) {
        view.items = items
    }
}

final class EdithContextMenuView: NSView {
    var items: @MainActor () -> [EdithMenuItem] = { [] }
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
    private var probing = false

    private static let swiftUIBundle = Bundle(for: NSHostingView<EmptyView>.self)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    static func opensMenu(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown, .rightMouseUp: true
        case .leftMouseDown, .leftMouseUp: event.modifierFlags.contains(.control)
        default: false
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !probing, !isHidden, let event = currentEvent(), Self.opensMenu(event),
            frame.contains(point), !embeddedViewOwnsMenu(at: event.locationInWindow)
        else { return nil }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let built = EdithMenu.normalized(items())
        guard !built.isEmpty else { return nil }
        return EdithMenu.makeMenu(built)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let menu = menu(for: event) else {
            super.mouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func embeddedViewOwnsMenu(at windowPoint: NSPoint) -> Bool {
        guard let root = window?.contentView else { return false }
        probing = true
        defer { probing = false }
        let point = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var view = root.hitTest(point)
        while let current = view, !isDescendant(of: current) {
            if current.menu != nil || Self.overridesMenu(type(of: current)) { return true }
            view = current.superview
        }
        return false
    }

    private static func overridesMenu(_ type: AnyClass) -> Bool {
        guard Bundle(for: type) != swiftUIBundle else { return false }
        let selector = #selector(NSView.menu(for:))
        return class_getMethodImplementation(type, selector)
            != class_getMethodImplementation(NSView.self, selector)
    }
}

@MainActor
final class EdithMenuAnchor {
    weak var view: NSView?

    func present(_ menu: NSMenu) {
        guard let view, view.window != nil, !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

struct EdithMenuAnchorRegion: NSViewRepresentable {
    let anchor: EdithMenuAnchor

    func makeNSView(context: Context) -> EdithMenuAnchorView {
        let view = EdithMenuAnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: EdithMenuAnchorView, context: Context) {
        anchor.view = view
    }
}

final class EdithMenuAnchorView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

public struct EdithMenuButton<Label: View>: View {
    private let items: @MainActor () -> [EdithMenuItem]
    private let label: Label
    @State private var anchor = EdithMenuAnchor()

    public init(
        items: @escaping @MainActor () -> [EdithMenuItem], @ViewBuilder label: () -> Label
    ) {
        self.items = items
        self.label = label()
    }

    public var body: some View {
        Button {
            let menu = EdithMenu.makeMenu(items())
            let anchor = anchor
            DispatchQueue.main.async { anchor.present(menu) }
        } label: {
            label
        }
        .background(EdithMenuAnchorRegion(anchor: anchor).accessibilityHidden(true))
    }
}
