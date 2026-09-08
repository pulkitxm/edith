import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

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
        parent.endSheet(sheet)
        #expect(!monitor.shouldDismiss(for: try mouse(in: parent, at: outside)))
    }

    @Test func disclosureRespondsAcrossLabelWhitespaceAndChevron() async throws {
        let probe = DisclosureProbe()
        let host = NSHostingView(rootView: DisclosureFixture(probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 180)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        for x in [32.0, 180, 324] {
            probe.expanded = false
            try await Task.sleep(for: .milliseconds(30))
            let point = NSPoint(x: x, y: 180 - 20 - 18)
            window.sendEvent(try mouse(in: window, at: point))
            window.sendEvent(try mouse(in: window, at: point, type: .leftMouseUp))
            try await Task.sleep(for: .milliseconds(30))
            #expect(probe.expanded, "Disclosure did not expand at x = \(x)")
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    @Test(arguments: [900.0, 560.0])
    func quickLookKeepsInsideClicksAndDismissesOutsideClicks(width: Double) async throws {
        let session = MachineSession(
            machine: Machine(name: "Sample machine", host: "192.0.2.1"), local: false,
            observesWakeRequests: false)
        let model = FinderModel(session: session)
        model.quickLookPath = "/sample/report.txt"
        let host = NSHostingView(
            rootView: QuickLookOverlay(model: model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try mouse(in: window, at: NSPoint(x: width / 2, y: 350), type: type))
        }
        #expect(model.quickLookPath != nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try mouse(in: window, at: NSPoint(x: 10, y: 10), type: type))
        }
        #expect(model.quickLookPath == nil)
        #expect(session.state == .disconnected)
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

@MainActor @Observable
private final class DisclosureProbe {
    var expanded = false
}

private struct DisclosureFixture: View {
    @Bindable var probe: DisclosureProbe

    var body: some View {
        DisclosureGroup(isExpanded: $probe.expanded) {
            Text("Sample event details")
        } label: {
            Text("Sample event").frame(height: 20)
        }
        .disclosureGroupStyle(EdithDisclosureGroupStyle())
        .padding(20)
        .frame(width: 360, height: 180, alignment: .topLeading)
    }
}
