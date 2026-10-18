import AppKit
import SwiftUI
import Testing

@testable import EdithExtensionUI

@MainActor
@Suite(.serialized) struct PresentationInteractionTests {
    @Test func outsideClickTargetsOnlyThePresentingWindow() throws {
        let parent = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled])
        let sheet = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320), styleMask: [.titled])
        let other = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200))
        let monitor = SheetDismissalView()
        sheet.contentView = monitor
        parent.orderBack(nil)
        parent.beginSheet(sheet)
        defer {
            monitor.stopMonitoring()
            if sheet.sheetParent != nil { parent.endSheet(sheet) }
            sheet.orderOut(nil)
            parent.orderOut(nil)
            other.orderOut(nil)
        }

        var dismissals = 0
        monitor.dismiss = { dismissals += 1 }
        let outside = NSPoint(x: 20, y: 20)
        #expect(monitor.shouldDismiss(for: try mouse(in: parent, at: outside)))
        #expect(!monitor.shouldDismiss(for: try mouse(in: sheet, at: outside)))
        #expect(!monitor.shouldDismiss(for: try mouse(in: other, at: outside)))
        #expect(!monitor.shouldDismiss(for: try mouse(in: parent, at: NSPoint(x: -10, y: -10))))
        let inside = parent.convertPoint(
            fromScreen: NSPoint(x: sheet.frame.midX, y: sheet.frame.midY))
        #expect(!monitor.shouldDismiss(for: try mouse(in: parent, at: inside)))
        #expect(
            !monitor.shouldDismiss(for: try mouse(in: parent, at: outside, type: .rightMouseDown)))
        NSApp.sendEvent(try mouse(in: parent, at: outside))
        #expect(dismissals == 1)
        monitor.dismissible = false
        #expect(!monitor.shouldDismiss(for: try mouse(in: parent, at: outside)))
        monitor.dismissible = true
        let child = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 120), styleMask: [.titled])
        sheet.beginSheet(child)
        #expect(!monitor.shouldDismiss(for: try mouse(in: parent, at: outside)))
        sheet.endSheet(child)
        child.orderOut(nil)
        parent.endSheet(sheet)
        #expect(!monitor.shouldDismiss(for: try mouse(in: parent, at: outside)))
    }

    @Test func escapeHonorsTheOwnersDismissalPolicy() {
        #expect(
            SheetDismissalPolicy.escape(
                keyCode: 53, modifiers: [], ownsKeyWindow: true, dismissible: true,
                dismissOnEscape: true))
        #expect(
            !SheetDismissalPolicy.escape(
                keyCode: 53, modifiers: [], ownsKeyWindow: false, dismissible: true,
                dismissOnEscape: true))
        #expect(
            !SheetDismissalPolicy.escape(
                keyCode: 53, modifiers: [], ownsKeyWindow: true, dismissible: false,
                dismissOnEscape: true))
        #expect(
            !SheetDismissalPolicy.escape(
                keyCode: 53, modifiers: [], ownsKeyWindow: true, dismissible: true,
                dismissOnEscape: false))
        #expect(
            !SheetDismissalPolicy.escape(
                keyCode: 36, modifiers: [], ownsKeyWindow: true, dismissible: true,
                dismissOnEscape: true))
        for modifiers in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            #expect(
                !SheetDismissalPolicy.escape(
                    keyCode: 53, modifiers: modifiers, ownsKeyWindow: true, dismissible: true,
                    dismissOnEscape: true))
        }
    }

    private func mouse(
        in window: NSWindow, at point: NSPoint, type: NSEvent.EventType = .leftMouseDown
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }
}
