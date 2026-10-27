import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import MicMuteExtension

@MainActor @Suite(.serialized) struct ControlSettingsLayoutTests {
    @Test func settingsScrollInsideTheirPresentation() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store)
        defer { model.stop() }
        let state = ExtensionPresentationState(
            compact: false, visible: false, availableWidth: 560, intrinsic: false)
        let host = NSHostingView(
            rootView: state.withContext {
                ExtensionPageHost {
                    ControlSettingsHost(presentation: model) {
                        Form { MicMuteRows(presentation: model) }.edithForm()
                    }
                }
            })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let scrollers = Self.scrollViews(in: host)
        #expect(!scrollers.isEmpty)
        for scroller in scrollers {
            #expect(scroller.convert(scroller.bounds, to: host).height <= 120)
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
