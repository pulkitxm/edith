import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

struct HomeMeetingsCard: View {
    @Environment(\.surfacePresentation) private var presentation
    let dark: Bool
    let store: CalendarUIFacade
    var authorized: (() -> Bool)?
    var grantAccess: (() -> Void)?
    let open: () -> Void
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    private var theme: Color { themeColor(themeName) }
    private var blurCalendar: Bool { store.blurEvents }

    private var todayEvents: [CalendarEventPayload] {
        store.events.filter {
            Calendar.current.isDateInToday($0.start)
                && (presentation?.tile.sourceIDs?.contains($0.calendarID) ?? true)
        }
    }

    var body: some View {
        PageCard(title: "Today's meetings", note: note) {
            VStack(alignment: .leading, spacing: UIScale.pt(0)) {
                if !store.loaded {
                    LoadingContainer(
                        state: store.error == nil ? .loading : .error,
                        title: "Calendar unavailable",
                        message: store.error ?? "Reading your schedule.",
                        retry: store.refresh
                    ) {
                        EmptyView()
                    } placeholder: {
                        SkeletonBlock(height: UIScale.pt(70))
                    }
                } else if !(authorized?() ?? store.authorized) {
                    accessPrompt
                } else if todayEvents.isEmpty {
                    Text("No meetings today. Clear runway.")
                        .font(.system(size: UIScale.pt(12.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(maxWidth: .infinity, minHeight: UIScale.pt(70))
                } else {
                    ForEach(todayEvents.prefix(presentation?.tile.itemLimit ?? 6), id: \.id) {
                        event in
                        row(event)
                        if event != todayEvents.prefix(presentation?.tile.itemLimit ?? 6).last {
                            Divider().opacity(0.4)
                        }
                    }
                }
                openCalendar
            }
        }
        .pageTask(cancel: store.suspend) { await store.observe() }
    }

    private var note: String {
        guard authorized?() ?? store.authorized else { return "" }
        let count = todayEvents.count
        return count == 0 ? "" : "\(count) event\(count == 1 ? "" : "s")"
    }

    private func row(_ event: CalendarEventPayload) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
            if presentation?.tile.shows("time") != false {
                Text(timeLabel(event))
                    .font(DashSkin.mono(11))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(event.title)
                .font(.system(size: UIScale.pt(12.5)))
                .lineLimit(1)
                .foregroundStyle(DashSkin.ink(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .presenterBlur(blurCalendar)
            if MeetingLink.url(for: event) != nil, presentation?.tile.showActions != false,
                presentation?.tile.shows("join") != false
            {
                Button {
                    store.perform(.join, eventID: event.id)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(theme)
                }
                .buttonStyle(.edith(.toolbar))
                .help("Join meeting")
            }
        }
        .padding(.vertical, UIScale.pt(6))
    }

    private func timeLabel(_ event: CalendarEventPayload) -> String {
        guard !event.isAllDay else { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    private var accessPrompt: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Grant calendar access to see today's schedule.")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            Spacer()
            Button("Grant…") {
                if let grantAccess { grantAccess() } else { store.perform(.permission) }
            }
            .buttonStyle(.edith(.toolbar))
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(theme)
        }
        .padding(.vertical, UIScale.pt(14))
    }

    @ViewBuilder private var openCalendar: some View {
        if presentation?.tile.showActions != false {
            Button(action: open) {
                HStack(spacing: UIScale.pt(4)) {
                    Text("Open Calendar")
                    Image(systemName: "arrow.right")
                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                }
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(DashSkin.accentDeep(dark))
            }
            .buttonStyle(.edith(.borderless))
            .padding(.top, UIScale.pt(10))
        }
    }
}

struct CalendarHomeScene: View {
    let tile: SurfaceTile
    let store: CalendarUIFacade
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HomeMeetingsCard(dark: scheme == .dark, store: store, open: open)
            .environment(
                \.surfacePresentation,
                SurfacePresentation(
                    tile: tile,
                    layout: SurfaceHostContext.current?.layout(.home)
                        ?? SurfaceLayout.standard(.home)))
    }
}
