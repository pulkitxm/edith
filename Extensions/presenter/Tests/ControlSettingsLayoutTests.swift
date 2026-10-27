import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import PresenterExtension

@MainActor @Suite(.serialized) struct ControlSettingsLayoutTests {
    @Test func tallSettingsScrollInsideTheirPresentation() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = ControlPresentation(client: nil, defaults: SharedDefaults.store)
        defer { model.stop() }
        let state = ExtensionPresentationState(
            compact: false, visible: false, availableWidth: 560, intrinsic: false)
        let host = NSHostingView(
            rootView: state.withContext {
                ExtensionPageHost {
                    ControlSettingsHost(presentation: model) {
                        Form { PresenterRows(presentation: model) }.edithForm()
                    }
                }
            })
        let window = PresenterTestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let scrollers = Self.scrollViews(in: host)
        #expect(!scrollers.isEmpty)
        for scroller in scrollers {
            #expect(scroller.convert(scroller.bounds, to: host).height <= 320)
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
