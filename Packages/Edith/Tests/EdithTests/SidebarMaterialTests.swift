import AppKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct SidebarMaterialTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func surfaceIsOpaqueInEveryAccessibilityState(scheme: ColorScheme) throws {
        let host = NSHostingView(
            rootView: SidebarMaterial()
                .environment(\.colorScheme, scheme))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        #expect(effects(in: host).isEmpty)
    }

    private func effects(in view: NSView) -> [NSVisualEffectView] {
        (view as? NSVisualEffectView).map { [$0] }
            ?? view.subviews.flatMap { effects(in: $0) }
    }
}
