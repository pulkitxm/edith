import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite struct SurfaceCalendarTests {
    @Test func calendarRejectsImpossibleDatesDuplicateDaysAndUnboundedRanges() throws {
        for date in ["2026-02-29", "2026-13-01", "0000-01-01", "2026-1-01", "2026-04-31"] {
            #expect(SurfaceCalendarDay.parse(date) == nil)
        }
        #expect(SurfaceCalendarDay.parse("2024-02-29") != nil)
        let day = SurfaceCalendarDay("day", date: "2026-01-01", level: 2, value: "$3")
        for days in [
            [day, day], [day, .init("other", date: "2027-02-01", level: 1, value: "")],
            [.init("invalid", date: "2026-01-01", level: 5, value: "")],
        ] {
            #expect(throws: ExtensionPeerError.self) {
                _ = try SurfaceSnapshot(
                    providerID: "usage", calendars: [.init("activity", "Activity", days: days)]
                ).encoded()
            }
        }
    }

    @Test func selectedSourcesFieldsAndActionsProjectCalendarContent() throws {
        let day = SurfaceCalendarDay(
            "day", date: "2026-01-01", level: 2, value: "$3",
            action: .init("show-day", "Open day", "calendar", field: "open"))
        let snapshot = SurfaceSnapshot(
            providerID: "usage",
            calendars: [.init("activity", "Activity", days: [day], sourceID: "local")])
        _ = try snapshot.encoded()
        var tile = SurfaceTile(.usage)
        tile.showActions = false
        #expect(SurfaceCommandService.project(snapshot, tile: tile).controlActions.isEmpty)
        tile.showActions = true
        #expect(
            SurfaceCommandService.project(snapshot, tile: tile).controlActions.map(\.id) == [
                "show-day"
            ])
        tile.sourceIDs = ["other"]
        #expect(SurfaceCommandService.project(snapshot, tile: tile).calendars?.isEmpty == true)
        tile.sourceIDs = nil
        tile.hiddenFields.insert("chart")
        #expect(SurfaceCommandService.project(snapshot, tile: tile).calendars == nil)
    }

    @MainActor @Test func staleCalendarActionsAreRejectedAndPresenterMaskingRemovesAllCells()
        async throws
    {
        let request = SurfaceSnapshotRequest(target: .home, tile: .init(.usage))
        let action = SurfaceActionRequest(snapshot: request, actionID: "removed-day")
        var performed = false
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await SurfaceCommandService.execute(
                providerID: "usage", command: "surface.perform",
                payload: action.encoded(providerID: "usage"),
                snapshot: { _ in .init(providerID: "usage") }, perform: { _ in performed = true },
                privacyValues: { [:] })
        }
        #expect(!performed)
        let data = try await SurfaceCommandService.execute(
            providerID: "usage", command: "surface.snapshot",
            payload: request.encoded(providerID: "usage"),
            snapshot: { _ in
                Issue.record("Private calendar discovery ran while masked")
                return .init(providerID: "usage")
            }, perform: { _ in }, privacyValues: { ["active": "1", "blurMoney": "1"] })
        #expect(try SurfaceSnapshot.decode(data, providerID: "usage").calendars == nil)
    }
}
