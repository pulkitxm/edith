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

    private var events: [CalendarEventPayload] {
        Array(
            CalendarWidgetEvents.selected(store.events, tile: tile, target: .notch)
                .prefix(tile.itemLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tile.dense ? 8 : 12) {
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
                    accessPrompt
                } else if events.isEmpty {
                    Text("No upcoming meetings").font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: tile.dense ? 8 : 10) {
                        ForEach(events, id: \.id) { event in row(event) }
                    }
                }
            } placeholder: {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 160, height: 10)
                    SkeletonBlock(width: 110, height: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if store.loaded, let error = store.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error).font(.edithText(.caption2)).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Retry", action: store.refresh).buttonStyle(.edith(.borderless))
                        .font(.edithText(.caption))
                }
            }
            if tile.showActions, store.authorized {
                Button(action: open) {
                    Label("Open Calendar", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.edith(.borderless))
                .font(.edithText(.caption).weight(.medium))
                .foregroundStyle(DashSkin.accent(true))
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

    private var accessPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                PageGuideBadge(symbolName: "calendar.badge.exclamationmark", size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar access needed").font(.edithText(.caption).weight(.semibold))
                    Text("Allow it to see your next meetings here.")
                        .font(.edithText(.caption2)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Allow Access") { store.perform(.permission) }
                .buttonStyle(.edith(.primary))
                .controlSize(.small)
                .fixedSize()
                .help("Allow Edith to read your calendar")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ event: CalendarEventPayload) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.edithText(.caption).weight(.medium))
                    .lineLimit(tile.dense ? 1 : 2).presenterBlur(store.blurEvents)
                if tile.showDetails, tile.shows("time") {
                    Text(
                        event.isAllDay
                            ? "All day"
                            : event.start.formatted(.dateTime.hour().minute())
                                + " to " + event.end.formatted(.dateTime.hour().minute())
                    )
                    .font(.edithText(.caption2)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if tile.showActions, tile.shows("join"), MeetingLink.url(for: event) != nil {
                Button {
                    store.perform(.join, eventID: event.id)
                } label: {
                    Image(systemName: "video.fill")
                }
                .buttonStyle(.edith(.iconOnly, tint: DashSkin.accent(true)))
                .help("Join meeting").accessibilityLabel("Join meeting")
            }
        }
    }
}
