import AppKit
import EdithExtensionSupport
import EventKit
import Foundation

@MainActor
final class CalendarSurface {
    private let store: CalendarStore
    private let presentation: CalendarPresentationState
    private let open: @MainActor (URL) -> Bool
    private let authorized: @MainActor () -> Bool

    init(
        store: CalendarStore, presentation: CalendarPresentationState,
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        authorized: (@MainActor () -> Bool)? = nil
    ) {
        self.store = store; self.presentation = presentation; self.open = open
        self.authorized = authorized ?? { store.authStatus == .fullAccess }
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        let request: SurfaceSnapshotRequest
        switch command {
        case "surface.snapshot":
            request = try SurfaceSnapshotRequest.decode(payload, providerID: "calendar")
        case "surface.perform":
            let action = try SurfaceActionRequest.decode(payload, providerID: "calendar")
            request = action.snapshot
            guard action.value == nil, authorized(),
                let event = selected(request.tile).prefix(request.tile.itemLimit).first(where: {
                    "join:" + $0.id == action.actionID
                }),
                request.tile.showActions, request.tile.shows("join"),
                let url = MeetingLink.url(for: event)
            else { throw ExtensionPeerError.invalidRequest }
            try Task.checkCancellation()
            guard open(url) else {
                throw ExtensionPeerError.rejected("The meeting could not open.")
            }
        default: throw ExtensionPeerError.invalidRequest
        }
        presentation.refresh()
        store.refreshAuthStatus()
        if command == "surface.snapshot" { _ = await store.refreshAndWait() }
        try Task.checkCancellation()
        return try snapshot(request.tile).encoded()
    }

    func snapshot(_ tile: SurfaceTile, now: Date = Date()) -> SurfaceSnapshot {
        guard authorized() else {
            return .init(
                providerID: "calendar", message: "Open Calendar to grant access to your meetings.",
                updatedAt: now)
        }
        let events = selected(tile, now: now)
        let privateContent = presentation.blurEvents
        var sourceIDs = Set<String>()
        let sources =
            privateContent
            ? []
            : store.events.compactMap { event -> SurfaceSourceChoice? in
                guard !event.calendarID.isEmpty, event.calendarID.utf8.count <= 2048,
                    sourceIDs.insert(event.calendarID).inserted
                else { return nil }
                return .init(
                    event.calendarID,
                    String((event.calendar.isEmpty ? "Calendar" : event.calendar).prefix(256)))
            }.prefix(100).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        let rows = events.prefix(tile.itemLimit).compactMap { event -> SurfaceDataRow? in
            guard !event.id.isEmpty, event.id.utf8.count <= 480 else { return nil }
            let actions: [SurfaceAction] =
                tile.showActions && tile.shows("join") && MeetingLink.url(for: event) != nil
                ? [.init("join:" + event.id, "Join", "video.fill", field: "join")] : []
            return .init(
                event.id,
                sourceID: privateContent
                    ? "hidden" : event.calendarID.isEmpty ? "unknown" : event.calendarID,
                title: privateContent
                    ? "Meeting"
                    : String((event.title.isEmpty ? "Untitled meeting" : event.title).prefix(256)),
                detail: privateContent || !tile.showDetails
                    ? "" : String(event.calendar.prefix(256)),
                value: tile.shows("time")
                    ? (event.isAllDay
                        ? "All day" : event.start.formatted(date: .omitted, time: .shortened)) : "",
                icon: "calendar", actions: actions)
        }
        return .init(
            providerID: "calendar", rows: rows, sources: sources,
            message: events.isEmpty ? "No upcoming meetings in this selection." : nil,
            updatedAt: now)
    }

    private func selected(_ tile: SurfaceTile, now: Date = Date()) -> [CalendarEventPayload] {
        CalendarDayEvents.sorted(CalendarDayEvents.deduplicated(store.events)).filter {
            $0.end >= now && (tile.sourceIDs?.contains($0.calendarID) ?? true)
        }
    }
}
