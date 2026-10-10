import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

enum CalendarWidgetEvents {
    static func selected(
        _ events: [CalendarEventPayload], tile: SurfaceTile, target: SurfaceTarget,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [CalendarEventPayload] {
        events.filter {
            (target == .home ? calendar.isDate($0.start, inSameDayAs: now) : $0.end > now)
                && (tile.sourceIDs?.contains($0.calendarID) ?? true)
        }
    }
}

struct CalendarNotchScene: View {
    let tile: SurfaceTile
    let store: CalendarUIFacade
    let open: () -> Void

    private var presentation: SurfacePresentation {
        SurfacePresentation(
            tile: tile,
            layout: SurfaceHostContext.current?.layout(.notch) ?? .standard(.notch))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tile.dense ? 6 : 10) {
            if tile.showTitle {
                Label(tile.displayTitle, systemImage: "calendar")
                    .font(.edithText(.caption).weight(.semibold))
            }
            LoadingContainer(
                state: store.loaded ? .content : store.error == nil ? .loading : .error,
                title: "Calendar unavailable", message: store.error ?? "Reading your schedule.",
                retry: store.refresh
            ) {
                if !store.authorized {
                    CalendarPermissionPrompt(style: .panel, accentColor: tile.highlightColor) {
                        store.perform(.permission)
                    }
                } else {
                    let events = Array(
                        CalendarWidgetEvents.selected(store.events, tile: tile, target: .notch)
                            .prefix(tile.itemLimit))
                    if events.isEmpty {
                        Text("No upcoming meetings").font(.edithText(.caption))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(events, id: \.id) { event in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title).font(.edithText(.caption))
                                    .lineLimit(tile.dense ? 1 : 2).presenterBlur(store.blurEvents)
                                if tile.showDetails, tile.shows("time") {
                                    Text(
                                        event.isAllDay
                                            ? "All day"
                                            : event.start.formatted(.dateTime.hour().minute())
                                                + " to "
                                                + event.end.formatted(.dateTime.hour().minute())
                                    )
                                    .font(.edithText(.caption2)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            if tile.showActions, tile.shows("join"),
                                MeetingLink.url(for: event) != nil
                            {
                                Button {
                                    store.perform(.join, eventID: event.id)
                                } label: {
                                    Image(systemName: "video.fill")
                                }.help("Join meeting").accessibilityLabel("Join meeting")
                            }
                        }
                    }
                }
            } placeholder: {
                SkeletonBlock(height: tile.dense ? 62 : 92)
            }
            if tile.showActions {
                Button("Open Calendar", action: open).font(.edithText(.caption))
            }
            if store.loaded, let error = store.error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.secondary)
                Button("Retry", action: store.refresh).buttonStyle(.edith(.borderless))
            }
        }
        .padding(presentation.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: presentation.cornerRadius)
        )
        .environment(\.surfacePresentation, presentation)
        .pageTask(cancel: store.suspend) { await store.observe() }
    }
}
