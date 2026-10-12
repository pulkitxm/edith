import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import CalendarExtension

@MainActor @Suite(.serialized) struct CalendarNativePresentationTests {
    @Test(arguments: [640.0, 1000.0], [false, true])
    func originalAgendaRendersAndDispatchesRichActionsOffscreen(width: Double, dark: Bool)
        async throws
    {
        let priorScale = UIScale.current
        UIScale.apply(1.5)
        defer { UIScale.apply(priorScale) }
        var joined: [String] = []
        var directed: [String] = []
        var loaded = 0
        let event = CalendarEventPayload(
            id: "synthetic", title: "Synthetic planning", calendar: "Synthetic team",
            start: Date(), end: Date().addingTimeInterval(600), isAllDay: false,
            location: "Synthetic hall", meetingURL: "https://meet.google.com/synthetic",
            notes: "Synthetic agenda details", isRecurring: true, hasAlarms: true)
        let host = NSHostingView(
            rootView:
                CalendarAgendaView(
                    days: CalendarDayEvents.groupedByDay([event]),
                    style: .page(compact: width < 800, rowBackground: .clear, strokeColor: .gray),
                    accentColor: .blue, blurEvents: false, onLoadMore: { loaded += 1 },
                    onOpenMeeting: { joined.append($0.id) },
                    onDirections: { directed.append($0.id) }
                )
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
        let fixture = UnorderedCalendarWindow(host: host, width: width)
        defer { fixture.close() }
        await fixture.layout()
        #expect(find(host, label: "Synthetic planning") != nil)
        #expect(find(host, label: "Synthetic hall") != nil)
        let join = try #require(find(host, label: "Join"))
        _ = (join as AnyObject).accessibilityPerformPress?()
        let directions = try #require(find(host, label: "Directions"))
        _ = (directions as AnyObject).accessibilityPerformPress?()
        #expect(joined == [event.id] && directed == [event.id])
        let details = try #require(find(host, label: "Details"))
        _ = (details as AnyObject).accessibilityPerformPress?()
        await fixture.layout()
        #expect(find(host, label: "Synthetic agenda details") != nil)
        #expect(!fixture.window.isVisible)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        #expect(loaded <= 1)
    }

    @Test func originalPermissionPromptUsesOnlyItsInjectedCallback() async throws {
        var grants = 0
        let host = NSHostingView(
            rootView:
                CalendarPermissionPrompt(
                    style: .page(compact: true, rowBackground: .clear, strokeColor: .gray),
                    accentColor: .blue, onGrant: { grants += 1 }
                )
                .environment(\.automaticViewActionsEnabled, false))
        let fixture = UnorderedCalendarWindow(host: host, width: 420)
        defer { fixture.close() }
        await fixture.layout()
        let grant = try #require(find(host, label: "Grant…"))
        _ = (grant as AnyObject).accessibilityPerformPress?()
        #expect(grants == 1 && !fixture.window.isVisible)
    }

    @Test func originalScopedControllerFactoryMatchesItsPresentationAndShutsDownOnlyTheFacade()
        async throws
    {
        let facade = CalendarUIFacade(invoke: { _, _ in
            try JSONEncoder().encode(
                CalendarUISnapshot(
                    authorized: true, blurEvents: false, days: 14, events: []))
        })
        defer { facade.shutdown() }
        let tile = SurfaceTile(.calendar)
        let scene = CalendarUIPresentation(
            facade: facade, route: .init(location: .home, tile: tile))
        #expect(
            scene.matches([
                "location": "home", "target": "home", "section": "calendar",
                "tile": try JSONEncoder().encode(tile),
            ]))
        #expect(!scene.matches(["location": "main", "section": "calendar"]))
        #expect(
            !scene.matches([
                "location": "home", "section": "other", "tile": try JSONEncoder().encode(tile),
            ]))
        let controller = try #require(scene.controller())
        #expect(controller is NSHostingController<ExtensionPageHost<CalendarHomeScene>>)
        #expect(controller.view.window == nil)
        await facade.refreshAndWait()
        #expect(facade.authorized)
        scene.shutdown()
        #expect(!facade.authorized && facade.events.isEmpty)
        let runtime = ExtensionRuntime()
        #expect((runtime.execute(["operation": "view"]) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(
            (runtime.execute(["operation": "configureUI", "remoteUI": true]) as? NSDictionary)?[
                "ok"] as? Bool == false)
    }

    @Test func releasingTheOriginalControllerReleasesItsPresentationFacade() async throws {
        weak var released: CalendarUIFacade?
        var scene: CalendarUIPresentation?
        var invalidated = 0
        autoreleasepool {
            let facade = CalendarUIFacade(
                invoke: { _, _ in Data("{}".utf8) }, invalidate: { invalidated += 1 })
            released = facade
            scene = CalendarUIPresentation(facade: facade, route: .init(location: .main))
            let controller = scene?.controller()
            #expect(controller != nil && scene?.isRetained == true)
        }
        await Task.yield()
        #expect(released == nil && scene?.isRetained == false && invalidated == 1)
    }

    @Test(arguments: [320.0, 640.0], [false, true])
    func originalNotchRendersScopedUpcomingMeetingsAndInjectedActions(width: Double, dark: Bool)
        async throws
    {
        let priorScale = UIScale.current
        UIScale.apply(1.5)
        defer { UIScale.apply(priorScale) }
        let now = Date()
        let events = [
            CalendarEventPayload(
                id: "past", title: "Synthetic finished meeting", calendarID: "one",
                start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800),
                isAllDay: false),
            CalendarEventPayload(
                id: "next", title: "Synthetic Notch meeting", calendarID: "one",
                start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200),
                isAllDay: false, meetingURL: "https://meet.google.com/synthetic"),
            CalendarEventPayload(
                id: "other", title: "Synthetic other source", calendarID: "two",
                start: now.addingTimeInterval(900), end: now.addingTimeInterval(1500),
                isAllDay: false),
        ]
        var joined: [String] = []
        let store = CalendarUIFacade(invoke: { operation, payload in
            if operation == "calendar.ui.action" {
                let action = try JSONDecoder().decode(CalendarUIActionRequest.self, from: payload)
                #expect(action.action == .join)
                joined.append(try #require(action.eventID))
            }
            return try JSONEncoder().encode(
                CalendarUISnapshot(authorized: true, blurEvents: false, days: 14, events: events))
        })
        defer { store.shutdown() }
        await store.refreshAndWait()
        var opened = 0
        var tile = SurfaceTile(.calendar)
        tile.sourceIDs = ["one"]
        tile.itemLimit = 1
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let fixture = UnorderedCalendarWindow(host: host, width: width)
        defer { fixture.close() }
        func render() async {
            host.rootView = AnyView(
                CalendarNotchScene(tile: tile, store: store, open: { opened += 1 })
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.automaticViewActionsEnabled, false)
                    .transaction { $0.animation = nil })
            await fixture.layout()
        }
        await render()
        #expect(find(host, label: "Synthetic Notch meeting") != nil)
        #expect(find(host, label: "Synthetic finished meeting") == nil)
        #expect(find(host, label: "Synthetic other source") == nil)
        let join = try #require(find(host, label: "Join meeting"))
        _ = (join as AnyObject).accessibilityPerformPress?()
        for _ in 0..<8 { await Task.yield() }
        #expect(joined == ["next"])
        let open = try #require(find(host, label: "Open Calendar"))
        _ = (open as AnyObject).accessibilityPerformPress?()
        #expect(opened == 1)
        tile.showActions = false
        await render()
        #expect(find(host, label: "Join meeting") == nil)
        #expect(find(host, label: "Open Calendar") == nil)
        #expect(!fixture.window.isVisible && !fixture.window.isKeyWindow)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
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

@MainActor
private final class UnorderedCalendarWindow {
    let window: NSWindow
    private let host: NSView
    private let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
        NSAccessibility.Attribute(rawValue: $0)
    }
    private let prior: [Any?]

    init(host: NSView, width: Double) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        prior = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        self.host = host
        window = UnorderedCalendarTestWindow(
            contentRect: .init(x: -10000, y: -10000, width: width, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
    }

    func layout() async {
        for _ in 0..<8 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func close() {
        window.contentView = nil
        for (attribute, value) in zip(attributes, prior) {
            NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
        }
    }
}

private final class UnorderedCalendarTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
