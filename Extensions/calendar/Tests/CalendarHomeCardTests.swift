import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import CalendarExtension

@MainActor @Suite(.serialized) struct CalendarHomeCardTests {
    @Test(arguments: [320.0, 640.0])
    func originalScheduleAndActionsRespectSavedWidgetOptions(width: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let today = Calendar.current.startOfDay(for: Date())
        let events = [
            CalendarEventPayload(
                id: "finished", title: "Synthetic finished meeting", calendar: "Synthetic",
                calendarID: "one", start: today.addingTimeInterval(3600),
                end: today.addingTimeInterval(7200), isAllDay: false),
            CalendarEventPayload(
                id: "tomorrow", title: "Synthetic tomorrow meeting", calendar: "Synthetic",
                calendarID: "one", start: today.addingTimeInterval(172800),
                end: today.addingTimeInterval(176400), isAllDay: false),
        ]
        let store = CalendarStore(
            snapshotStore: .init(file: root.appendingPathComponent("agenda.json")),
            fetch: { _ in events })
        let presentation = CalendarPresentationState(channel: nil)
        defer {
            store.shutdown(); presentation.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        _ = await store.refreshAndWait()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let prior = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, value) in zip(attributes, prior) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        var opened = 0
        var granted = 0
        var tile = SurfaceTile(.calendar)
        tile.sourceIDs = ["one"]
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = CalendarHomeTestWindow(
            contentRect: .init(x: -10000, y: -10000, width: width, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func render(authorized: Bool) async {
            host.rootView = AnyView(
                HomeMeetingsCard(
                    dark: false, store: store, calendarPresentation: presentation,
                    authorized: { authorized }, grantAccess: { granted += 1 }, open: { opened += 1 }
                )
                .environment(
                    \.surfacePresentation, SurfacePresentation(tile: tile, layout: .standard(.home))
                )
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
            for _ in 0..<8 {
                window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        await render(authorized: true)
        #expect(find(host, label: "Synthetic finished meeting") != nil)
        #expect(find(host, label: "Synthetic tomorrow meeting") == nil)
        let time =
            events[0].start.formatted(date: .omitted, time: .shortened) + "–"
            + events[0].end.formatted(date: .omitted, time: .shortened)
        #expect(find(host, label: time) != nil)
        let open = try #require(find(host, label: "Open Calendar"))
        _ = (open as AnyObject).accessibilityPerformPress?()
        #expect(opened == 1)
        tile.showActions = false
        tile.hiddenFields = ["time"]
        await render(authorized: true)
        #expect(find(host, label: "Open Calendar") == nil)
        #expect(find(host, label: time) == nil)
        #expect(find(host, label: "Synthetic finished meeting") != nil)
        tile.sourceIDs = []
        await render(authorized: true)
        #expect(find(host, label: "Synthetic finished meeting") == nil)
        #expect(find(host, label: "No meetings today. Clear runway.") != nil)
        await render(authorized: false)
        let grant = try #require(find(host, label: "Grant…"))
        _ = (grant as AnyObject).accessibilityPerformPress?()
        #expect(granted == 1)
        #expect(find(host, label: "Synthetic finished meeting") == nil)
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) })
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        let selector = NSSelectorFromString("accessibilityValue")
        if node.responds(to: selector),
            node.perform(selector)?.takeUnretainedValue() as? String == label
        {
            return node
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let found = find(child, label: label, depth: depth + 1) { return found }
        }
        for child in (node as? NSView)?.subviews ?? [] {
            if let found = find(child, label: label, depth: depth + 1) { return found }
        }
        return nil
    }
}

private final class CalendarHomeTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
