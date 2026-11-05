import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import CalendarExtension

extension RenderCapture {
    fileprivate static let cardVariants = [
        Variant(name: "light", width: 420, height: 300, zoom: 1, scheme: .light),
        Variant(name: "dark", width: 420, height: 300, zoom: 1, scheme: .dark),
        Variant(name: "zoomed", width: 560, height: 420, zoom: 1.6, scheme: .dark),
    ]

    fileprivate static let notchVariants = [
        Variant(name: "regular", width: 340, height: 260, zoom: 1, scheme: .dark),
        Variant(name: "zoomed", width: 420, height: 320, zoom: 1.6, scheme: .dark),
    ]
}

@MainActor @Suite(.serialized) struct CalendarRenderCaptureTests {
    private struct Unavailable: LocalizedError {
        var errorDescription: String? { "The calendar engine stopped responding." }
    }

    private static let today = Calendar.current.startOfDay(for: Date())

    private static func at(_ day: Int, _ hour: Double) -> Date {
        today.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
    }

    private static let blue = CalendarColorPayload(red: 0.2, green: 0.5, blue: 0.95, alpha: 1)
    private static let green = CalendarColorPayload(red: 0.2, green: 0.7, blue: 0.4, alpha: 1)
    private static let orange = CalendarColorPayload(red: 0.95, green: 0.55, blue: 0.2, alpha: 1)

    static let events = [
        CalendarEventPayload(
            id: "standup", title: "Synthetic team standup", calendar: "Work",
            calendarColor: blue, start: at(0, 9.5), end: at(0, 9.75), isAllDay: false,
            meetingURL: "https://meet.google.com/synthetic-standup",
            attendees: [
                .init(
                    name: "Alex Example", address: nil, status: "accepted", role: "required",
                    isCurrentUser: false),
                .init(
                    name: "Sam Sample", address: nil, status: "tentative", role: "required",
                    isCurrentUser: false),
            ], isRecurring: true),
        CalendarEventPayload(
            id: "review", title: "Design review for the sample launch", calendar: "Work",
            calendarColor: blue, start: at(0, 11), end: at(0, 12), isAllDay: false,
            meetingURL: "https://zoom.us/j/000000000"),
        CalendarEventPayload(
            id: "lunch", title: "Lunch with the synthetic crew", calendar: "Personal",
            calendarColor: green, start: at(0, 13), end: at(0, 14), isAllDay: false,
            location: "Sample Cafe, 1 Example Street", latitude: 1, longitude: 1),
        CalendarEventPayload(
            id: "offsite", title: "Synthetic planning offsite", calendar: "Work",
            calendarColor: orange, start: at(1, 0), end: at(2, 0), isAllDay: true),
        CalendarEventPayload(
            id: "interview", title: "Interview: sample candidate", calendar: "Work",
            calendarColor: blue, start: at(1, 15), end: at(1, 15.75), isAllDay: false,
            meetingURL: "https://meet.google.com/synthetic-interview", hasAlarms: true),
        CalendarEventPayload(
            id: "dentist", title: "Dentist", calendar: "Personal", calendarColor: green,
            start: at(3, 10), end: at(3, 10.5), isAllDay: false,
            location: "Example Dental Clinic"),
    ]

    private static func snapshot(authorized: Bool, events: [CalendarEventPayload]) -> Data {
        (try? JSONEncoder().encode(
            CalendarUISnapshot(
                authorized: authorized, blurEvents: false, days: 14, events: events))) ?? Data()
    }

    private static func store(authorized: Bool, events: [CalendarEventPayload]) async
        -> CalendarUIFacade
    {
        let data = snapshot(authorized: authorized, events: events)
        let store = CalendarUIFacade(invoke: { _, _ in data })
        await store.refreshAndWait()
        return store
    }

    private static func failing() async -> CalendarUIFacade {
        let store = CalendarUIFacade(invoke: { _, _ in throw Unavailable() })
        await store.refreshAndWait()
        return store
    }

    private static func failingAfterContent() async -> CalendarUIFacade {
        let data = snapshot(authorized: true, events: events)
        var calls = 0
        let store = CalendarUIFacade(invoke: { _, _ in
            calls += 1
            if calls > 1 { throw Unavailable() }
            return data
        })
        await store.refreshAndWait()
        await store.refreshAndWait()
        return store
    }

    @Test func pageRendersEveryStateAtEverySize() async throws {
        try await RenderCapture.withAccessibility {
            let permission = await Self.store(authorized: false, events: [])
            let empty = await Self.store(authorized: true, events: [])
            let populated = await Self.store(authorized: true, events: Self.events)
            let loading = CalendarUIFacade(invoke: { _, _ in Data() })
            let failed = await Self.failing()
            let stale = await Self.failingAfterContent()
            defer {
                for store in [permission, empty, populated, loading, failed, stale] {
                    store.shutdown()
                }
            }
            #expect(stale.loaded && stale.error != nil && !stale.events.isEmpty)
            let cases: [(String, CalendarUIFacade, String)] = [
                ("permission", permission, "Allow Calendar Access"),
                ("empty", empty, "Nothing coming up"),
                ("populated", populated, "Synthetic team standup"),
                ("loading", loading, "Calendar"),
                ("error", failed, "Retry"),
                ("stale", stale, "Synthetic team standup"),
            ]
            for (name, store, label) in cases {
                for variant in RenderCapture.layoutVariants {
                    let rendered = try await RenderCapture.render(
                        "calendar-page-\(name)", variant: variant
                    ) {
                        CalendarPage(store: store)
                    }
                    #expect(
                        RenderCapture.find(rendered.host, label: label) != nil,
                        "\(name) \(variant.name) is missing \(label)")
                }
            }
        }
    }

    @Test func homeAndNotchRenderEveryState() async throws {
        try await RenderCapture.withAccessibility {
            let permission = await Self.store(authorized: false, events: [])
            let empty = await Self.store(authorized: true, events: [])
            let populated = await Self.store(authorized: true, events: Self.events)
            let loading = CalendarUIFacade(invoke: { _, _ in Data() })
            defer {
                for store in [permission, empty, populated, loading] { store.shutdown() }
            }
            let tile = SurfaceTile(.calendar)
            let cases: [(String, CalendarUIFacade, String?, String?)] = [
                ("permission", permission, "Allow Calendar Access", "Allow Access"),
                ("empty", empty, "No meetings today.", "No upcoming meetings"),
                (
                    "populated", populated, "Design review for the sample launch",
                    "Synthetic planning offsite"
                ),
                ("loading", loading, nil, nil),
            ]
            for (name, store, homeLabel, notchLabel) in cases {
                for variant in RenderCapture.cardVariants {
                    let rendered = try await RenderCapture.render(
                        "calendar-home-\(name)", variant: variant
                    ) {
                        HomeMeetingsCard(dark: variant.scheme == .dark, store: store, open: {})
                            .environment(
                                \.surfacePresentation,
                                SurfacePresentation(tile: tile, layout: .standard(.home))
                            )
                            .padding(UIScale.pt(16))
                    }
                    if let homeLabel {
                        #expect(RenderCapture.find(rendered.host, label: homeLabel) != nil)
                    }
                }
                for variant in RenderCapture.notchVariants {
                    let rendered = try await RenderCapture.render(
                        "calendar-notch-\(name)", variant: variant
                    ) {
                        CalendarNotchScene(tile: tile, store: store, open: {})
                            .padding(12)
                            .frame(
                                maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
                            )
                            .background(.black)
                    }
                    if let notchLabel {
                        #expect(
                            RenderCapture.find(rendered.host, label: notchLabel) != nil,
                            "notch \(name) \(variant.name) is missing \(notchLabel)")
                    }
                }
            }
        }
    }

    @Test func settingsRenderBothAccessStates() async throws {
        try await RenderCapture.withAccessibility {
            let denied = await Self.store(authorized: false, events: [])
            let allowed = await Self.store(authorized: true, events: Self.events)
            defer {
                denied.shutdown()
                allowed.shutdown()
            }
            for (name, store, label) in [
                ("denied", denied, "Allow Calendar Access"),
                ("allowed", allowed, "Open Calendar App"),
            ] {
                for variant in RenderCapture.layoutVariants {
                    let rendered = try await RenderCapture.render(
                        "calendar-settings-\(name)", variant: variant
                    ) {
                        CalendarSettingsScene(store: store)
                    }
                    #expect(RenderCapture.find(rendered.host, label: label) != nil)
                }
            }
        }
    }
}

extension RenderCapture {
    fileprivate static let layoutVariants =
        variants + [Variant(name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)]
}
