import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import CalendarExtension

@Suite(.serialized) @MainActor struct CalendarScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: enabled)) func scrollingTheLongestSyntheticAgenda() async throws {
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        let timing = try await Self.measure(
            days: CalendarEventQuery.maximumDays, perDay: 8, frames: frames)
        print(
            "calendar-scroll agenda: \(timing) reach=\(Int(timing.offsets.max() ?? 0)) slowAt=\(timing.slowOffsets)"
        )
    }

    @Test func scrollingStaysSmoothWithALongAgenda() async throws {
        let timing = try await Self.measure(days: 60, perDay: 5, frames: 60)
        print("calendar-regression agenda: \(timing)")
        #expect(timing.frames.count == 60)
        #expect((timing.offsets.max() ?? 0) > 500)
        #expect(timing.worst < 100)
        #expect(timing.median < 12)
    }

    static func measure(days: Int, perDay: Int, frames: Int) async throws -> ScrollTiming {
        let events = syntheticEvents(days: days, perDay: perDay)
        let snapshot = CalendarUISnapshot(
            authorized: true, blurEvents: false, days: days, events: events)
        let payload = try JSONEncoder().encode(snapshot)
        let facade = CalendarUIFacade(invoke: { _, _ in payload })
        defer { facade.shutdown() }
        await facade.refreshAndWait()
        #expect(facade.groupedDays.count >= days - 1)
        let (window, host) = ScrollHarness.host(
            CalendarPage(store: facade)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil },
            size: CGSize(width: 1120, height: 860))
        await ScrollHarness.settle(host, for: .seconds(1))
        let scroll = try #require(ScrollHarness.scrollView(in: host))
        #expect(scroll.frame.height <= host.bounds.height)
        #expect((scroll.documentView?.frame.height ?? 0) > host.bounds.height * 2)
        let timing = await ScrollHarness.scroll(host, frames: frames)
        window.orderOut(nil)
        window.contentView = nil
        return timing
    }

    static func syntheticEvents(days: Int, perDay: Int) -> [CalendarEventPayload] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        var events: [CalendarEventPayload] = []
        for day in 0..<days {
            let date = calendar.date(byAdding: .day, value: day, to: start) ?? start
            for slot in 0..<perDay {
                let begin = date.addingTimeInterval(Double(8 + slot * 2) * 3_600)
                events.append(
                    CalendarEventPayload(
                        id: "synthetic-\(day)-\(slot)",
                        title: "Synthetic meeting \(day)-\(slot) with a longer descriptive title",
                        calendar: slot.isMultiple(of: 2) ? "Work" : "Personal",
                        calendarColor: CalendarColorPayload(
                            red: 0.2, green: 0.5 + Double(slot) / 20, blue: 0.8, alpha: 1),
                        start: begin, end: begin.addingTimeInterval(3_000),
                        isAllDay: slot == 0 && day.isMultiple(of: 5),
                        location: slot.isMultiple(of: 2) ? "Room \(slot)" : nil,
                        meetingURL: slot.isMultiple(of: 3)
                            ? "https://meet.example.test/\(day)-\(slot)" : nil,
                        attendees: (0..<3).map {
                            CalendarParticipantPayload(
                                name: "Person \($0)", address: "person\($0)@example.test",
                                status: "accepted", role: "required", isCurrentUser: $0 == 0)
                        }))
            }
        }
        return events
    }
}
