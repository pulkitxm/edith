import AppKit
import SwiftUI

@MainActor
final class PageScrollPositions {
    private var positions: [String: CGPoint] = [:]

    subscript(_ key: String) -> CGPoint {
        get { positions[key] ?? .zero }
        set { positions[key] = newValue }
    }
}

private struct PageLocationKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var pageLocation: String? {
        get { self[PageLocationKey.self] }
        set { self[PageLocationKey.self] = newValue }
    }
}

struct PageScrollPosition: NSViewRepresentable {
    let positions: PageScrollPositions
    let key: String

    func makeNSView(context: Context) -> PageScrollPositionView {
        let view = PageScrollPositionView()
        view.configure(positions: positions, key: key)
        return view
    }

    func updateNSView(_ view: PageScrollPositionView, context: Context) {
        view.configure(positions: positions, key: key)
    }

    static func dismantleNSView(_ view: PageScrollPositionView, coordinator: ()) {
        view.detach()
    }
}

final class PageScrollPositionView: NSView {
    private var positions: PageScrollPositions?
    private var key: String?
    private weak var scroll: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var restoring = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(positions: PageScrollPositions, key: String) {
        guard self.positions !== positions || self.key != key else { return }
        detach()
        self.positions = positions
        self.key = key
        attach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() } else { attach() }
    }

    private func attach() {
        guard scroll == nil, window != nil, let scroll = enclosingScrollView,
            positions != nil, key != nil
        else { return }
        self.scroll = scroll
        restoring = true
        scroll.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        observers.append(
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scroll, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restoring = false
                    self?.save()
                }
            })
        DispatchQueue.main.async { [weak self] in
            self?.restore()
        }
    }

    private func restore() {
        guard restoring, let positions, let key, let scroll, scroll.documentView != nil
        else { return }
        scroll.layoutSubtreeIfNeeded()
        let point = positions[key]
        let requested = NSRect(origin: point, size: scroll.contentView.bounds.size)
        let clamped = scroll.contentView.constrainBoundsRect(requested)
        scroll.contentView.scroll(to: clamped.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        restoring = false
        save()
    }

    private func save() {
        guard !restoring, let positions, let key, let scroll else { return }
        positions[key] = scroll.contentView.bounds.origin
    }

    func detach() {
        save()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        scroll = nil
        restoring = false
    }
}

private struct RetainedPageScrollPosition: ViewModifier {
    let key: String
    @Environment(\.studioScrollPositions) private var positions

    func body(content: Content) -> some View {
        content.background {
            if let positions { PageScrollPosition(positions: positions, key: key) }
        }
    }
}

extension View {
    func pageScrollPosition(_ key: String) -> some View {
        modifier(RetainedPageScrollPosition(key: key))
    }
}

private struct StudioScrollPositionsKey: EnvironmentKey {
    static let defaultValue: PageScrollPositions? = nil
}

extension EnvironmentValues {
    var studioScrollPositions: PageScrollPositions? {
        get { self[StudioScrollPositionsKey.self] }
        set { self[StudioScrollPositionsKey.self] = newValue }
    }
}
