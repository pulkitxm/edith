import AppKit
import EdithExtensionUI
import SwiftUI

@MainActor
final class EmbeddedMusicDetailHostingView: NSHostingView<
    ExtensionPageHost<EmbeddedMusicDetailOverlay>
>
{
    override func hitTest(_ point: NSPoint) -> NSView? {
        EmbeddedMusicDetailPresenter.shared.track == nil ? nil : super.hitTest(point)
    }
}

@MainActor
enum EmbeddedMusicDetailWindowOverlay {
    private struct Entry {
        let view: EmbeddedMusicDetailHostingView
        var holders: Int
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func overlayCount(in window: NSWindow) -> Int {
        window.contentView?.subviews.filter { $0 is EmbeddedMusicDetailHostingView }.count ?? 0
    }

    static func acquire(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if var entry = entries[key] {
            entry.holders += 1
            entries[key] = entry
            return
        }
        guard let content = window.contentView else { return }
        let view = EmbeddedMusicDetailHostingView(
            rootView: ExtensionPageHost { EmbeddedMusicDetailOverlay() })
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view, positioned: .above, relativeTo: nil)
        entries[key] = Entry(view: view, holders: 1)
    }

    static func release(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard var entry = entries[key] else { return }
        entry.holders -= 1
        if entry.holders > 0 {
            entries[key] = entry
            return
        }
        entry.view.removeFromSuperview()
        entries[key] = nil
    }
}

struct EmbeddedMusicWindowDetail: NSViewRepresentable {
    final class Anchor: NSView {
        private weak var held: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let held { EmbeddedMusicDetailWindowOverlay.release(held) }
            held = window
            if let window { EmbeddedMusicDetailWindowOverlay.acquire(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}
}

extension View {
    func musicWindowDetail() -> some View {
        ZStack {
            self
            EmbeddedMusicWindowDetail().frame(width: 0, height: 0).allowsHitTesting(false)
        }
    }
}
