import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarUISceneRouteTests {
    @Test func eachPresentationRequiresItsOwnSceneAndSurfaceTarget() throws {
        let tile = SurfaceTile(.calendar)
        let main: NSDictionary = ["section": "calendar", "location": "main"]
        let mainRoute = try #require(CalendarUISceneRoute(context: main))
        #expect(mainRoute.location == .main && mainRoute.target == nil && mainRoute.tile == nil)
        for location in [CalendarUISceneRoute.Location.home, .notch] {
            let context = try context(location: location.rawValue, tile: tile)
            let route = try #require(CalendarUISceneRoute(context: context))
            #expect(route.location == location && route.tile == tile)
            #expect(route.target?.rawValue == location.rawValue)
            let facade = CalendarUIFacade(invoke: { _, _ in Data() })
            let presentation = CalendarUIPresentation(facade: facade, route: route)
            defer { presentation.shutdown() }
            #expect(presentation.matches(context))
            let other = context.mutableCopy() as! NSMutableDictionary
            other["target"] = location == .home ? "notch" : "home"
            #expect(!presentation.matches(other))
            other.removeObject(forKey: "target")
            #expect(CalendarUISceneRoute(context: other) == nil)
        }
    }

    @Test func malformedOrHiddenTilesCannotBecomeNativeScenes() throws {
        var tile = SurfaceTile(.calendar)
        tile.hidden = true
        #expect(CalendarUISceneRoute(context: try context(location: "notch", tile: tile)) == nil)
        tile.hidden = false
        tile.itemLimit = 21
        #expect(CalendarUISceneRoute(context: try context(location: "home", tile: tile)) == nil)
        #expect(
            CalendarUISceneRoute(
                context: try context(location: "home", tile: SurfaceTile(.agents))) == nil)
        #expect(
            CalendarUISceneRoute(
                context: ["section": "calendar", "location": "main", "target": "home"]) == nil)
        #expect(
            CalendarUISceneRoute(
                context: [
                    "section": "calendar", "location": "main",
                    "tile": try JSONEncoder().encode(SurfaceTile(.calendar)),
                ]) == nil)
        #expect(CalendarUISceneRoute(context: ["section": "other", "location": "main"]) == nil)
        #expect(CalendarUISceneRoute(context: ["section": "calendar", "location": "other"]) == nil)
        #expect(
            CalendarUISceneRoute(
                context: [
                    "section": "calendar", "location": "home", "target": "home",
                    "tile": Data(repeating: 0, count: 65_537),
                ]) == nil)
    }

    @Test func homeKeepsTodayWhileNotchKeepsUpcomingAndEachFiltersItsOwnSources() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let day = calendar.startOfDay(for: today)
        let now = day.addingTimeInterval(43_200)
        let events = [
            event("finished", source: "one", start: day.addingTimeInterval(3600)),
            event("next", source: "one", start: day.addingTimeInterval(46_800)),
            event("other", source: "two", start: day.addingTimeInterval(50_400)),
            event("tomorrow", source: "one", start: day.addingTimeInterval(90_000)),
        ]
        var tile = SurfaceTile(.calendar)
        func selected(_ target: SurfaceTarget) -> [String] {
            CalendarWidgetEvents.selected(
                events, tile: tile, target: target, now: now, calendar: calendar
            ).map(\.id)
        }
        #expect(selected(.home) == ["finished", "next", "other"])
        #expect(selected(.notch) == ["next", "other", "tomorrow"])
        tile.sourceIDs = ["one"]
        #expect(selected(.home) == ["finished", "next"])
        #expect(selected(.notch) == ["next", "tomorrow"])
        tile.sourceIDs = []
        #expect(selected(.home).isEmpty && selected(.notch).isEmpty)
    }

    private func context(location: String, tile: SurfaceTile) throws -> NSDictionary {
        [
            "section": "calendar", "location": location, "target": location,
            "tile": try JSONEncoder().encode(tile),
        ]
    }

    private func event(_ id: String, source: String, start: Date) -> CalendarEventPayload {
        CalendarEventPayload(
            id: id, title: "Synthetic meeting", calendarID: source, start: start,
            end: start.addingTimeInterval(1800), isAllDay: false)
    }
}
