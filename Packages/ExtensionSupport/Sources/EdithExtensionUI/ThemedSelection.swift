import AppKit
import EdithExtensionCore
import SwiftUI

extension View {
    public func themedSelection() -> some View {
        modifier(ThemedSelectionModifier())
    }
}

private struct ThemedSelectionModifier: ViewModifier {
    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = "accent"
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content.background(
            ThemedSelectionAnchor(
                fill: AppTheme(storedName: themeName).accentNSColor(dark: dark)
                    .withAlphaComponent(dark ? 0.26 : 0.18),
                radius: UIScale.pt(6),
                inset: UIScale.pt(8)))
    }
}

private struct ThemedSelectionAnchor: NSViewRepresentable {
    let fill: NSColor
    let radius: CGFloat
    let inset: CGFloat

    func makeNSView(context: Context) -> ThemedSelectionPainter { ThemedSelectionPainter() }

    func updateNSView(_ painter: ThemedSelectionPainter, context: Context) {
        painter.fill = fill
        painter.radius = radius
        painter.inset = inset
        painter.schedule()
    }
}

final class ThemedSelectionFill: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ThemedSelectionPainter: NSView {
    var fill: NSColor = .clear
    var radius: CGFloat = 6
    var inset: CGFloat = 8
    private weak var table: NSTableView?
    private var fills: [ThemedSelectionFill] = []
    private var observers: [NSObjectProtocol] = []

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for view in fills { view.removeFromSuperview() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedule()
    }

    override func layout() {
        super.layout()
        if table == nil { schedule() }
    }

    func schedule() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            attach()
            paint()
        }
    }

    private func attach() {
        guard table == nil, window != nil, let found = nearestTable() else { return }
        table = found
        found.selectionHighlightStyle = .none
        found.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        let repaint: @Sendable (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.paint() }
        }
        observers = [
            center.addObserver(
                forName: NSTableView.selectionDidChangeNotification, object: found, queue: .main,
                using: repaint),
            center.addObserver(
                forName: NSView.frameDidChangeNotification, object: found, queue: .main,
                using: repaint),
        ]
    }

    private func nearestTable() -> NSTableView? {
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        var ancestor = superview
        while let view = ancestor {
            if let found = Self.table(in: view, at: center) { return found }
            ancestor = view.superview
        }
        return nil
    }

    private static func table(in view: NSView, at point: CGPoint) -> NSTableView? {
        if let table = view as? NSTableView {
            let area = table.enclosingScrollView ?? table
            return area.convert(area.bounds, to: nil).contains(point) ? table : nil
        }
        for child in view.subviews {
            if let table = table(in: child, at: point) { return table }
        }
        return nil
    }

    private func paint() {
        guard let table else { return }
        let selected = Array(table.selectedRowIndexes)
        while fills.count < selected.count {
            let view = ThemedSelectionFill()
            view.wantsLayer = true
            fills.append(view)
        }
        let firstRow = table.subviews.first { $0 is NSTableRowView }
        for (index, view) in fills.enumerated() {
            table.addSubview(view, positioned: .below, relativeTo: firstRow)
            guard index < selected.count else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            let edge = table.style == .inset ? inset + UIScale.pt(2) : inset
            view.frame = table.rect(ofRow: selected[index]).insetBy(dx: edge, dy: 0)
            view.layer?.backgroundColor = fill.cgColor
            view.layer?.cornerRadius = radius
        }
    }
}
