import AppKit
import SwiftUI
import Testing

@testable import MusicEmbeddedUI

@MainActor @Suite(.serialized) struct MusicDetailWindowOverlayTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }

    @Test func anchorsShareOneWindowWideOverlayAndRemoveItWhenGone() {
        let window = window()
        let first = EmbeddedMusicWindowDetail.Anchor()
        let second = EmbeddedMusicWindowDetail.Anchor()
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        #expect(EmbeddedMusicDetailWindowOverlay.overlayCount(in: window) == 1)
        first.removeFromSuperview()
        #expect(EmbeddedMusicDetailWindowOverlay.overlayCount(in: window) == 1)
        second.removeFromSuperview()
        #expect(EmbeddedMusicDetailWindowOverlay.overlayCount(in: window) == 0)
    }

    @Test func overlayPassesClicksThroughWhileNoTrackIsShown() throws {
        let window = window()
        let anchor = EmbeddedMusicWindowDetail.Anchor()
        window.contentView?.addSubview(anchor)
        let overlay = try #require(
            window.contentView?.subviews.first { $0 is EmbeddedMusicDetailHostingView })
        EmbeddedMusicDetailPresenter.shared.dismiss()
        #expect(overlay.hitTest(NSPoint(x: 100, y: 100)) == nil)
        anchor.removeFromSuperview()
    }
}
