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
    private var isAuthorized: Bool { authorized?() ?? store.authorized }
    private var limit: Int { presentation?.tile.itemLimit ?? 6 }
    private var showsActions: Bool { presentation?.tile.showActions != false }

    private var todayEvents: [CalendarEventPayload] {
        CalendarWidgetEvents.selected(
            store.events, tile: presentation?.tile ?? SurfaceTile(.calendar), target: .home)
    }

    var body: some View {
        PageCard(title: "Today's meetings", note: note) {
            VStack(alignment: .leading, spacing: 0) {
                if !store.loaded {
                    LoadingContainer(
                        state: store.error == nil ? .loading : .error,
                        title: "Calendar unavailable",
                        message: store.error ?? "Reading your schedule.",
                        retry: store.refresh
                    ) {
                        EmptyView()
                    } placeholder: {
                        skeleton
                    }
                } else if !isAuthorized {
                    PageEmptyState(
                        icon: .calendar,
                        title: "See today's meetings here",
                        message: "Allow Edith to read your calendar. It never changes your events.",
                        primary: PageAction(
                            "Allow Calendar Access", identifier: "calendar.home.grant"
                        ) {
                            if let grantAccess { grantAccess() } else { store.perform(.permission) }
                        },
                        style: .compact)
                } else if todayEvents.isEmpty {
                    Text("No meetings today.")
                        .font(.edithText(.callout))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: UIScale.pt(64))
                } else {
                    let visible = Array(todayEvents.prefix(limit))
                    ForEach(visible, id: \.id) { event in
                        row(event)
                        if event != visible.last { Divider() }
                    }
                }
                if store.loaded, let error = store.error {
                    HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                        EdithIconView(.warning)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(error).font(.edithText(.caption)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: UIScale.pt(8))
                        Button("Retry", action: store.refresh).buttonStyle(.edith(.secondary))
                    }
                    .padding(.top, UIScale.pt(12))
                }
                if showsActions, isAuthorized || !store.loaded {
                    Button(action: open) {
                        Label("Open Calendar", edith: .arrowRight)
                            .labelStyle(CalendarTrailingIconLabelStyle())
                    }
                    .buttonStyle(.edith(.borderless))
                    .font(.edithText(.callout).weight(.medium))
                    .foregroundStyle(DashSkin.accentDeep(dark))
                    .padding(.top, UIScale.pt(12))
                }
            }
        }
        .pageTask(cancel: store.suspend) { await store.observe() }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: UIScale.pt(12)) {
                    SkeletonBlock(width: 96, height: 12)
                    SkeletonBlock(width: index == 1 ? 120 : 180, height: 12)
                }
            }
        }
        .padding(.vertical, UIScale.pt(8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var note: String {
        guard store.loaded, isAuthorized else { return "" }
        let count = todayEvents.count
        return count == 0 ? "" : "\(count) event\(count == 1 ? "" : "s")"
    }

    private func row(_ event: CalendarEventPayload) -> some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            if presentation?.tile.shows("time") != false {
                Text(timeLabel(event))
                    .font(.edithText(.caption))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(event.title)
                .font(.edithText(.callout))
                .lineLimit(1)
                .foregroundStyle(DashSkin.ink(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .presenterBlur(store.blurEvents)
            if MeetingLink.url(for: event) != nil, showsActions,
                presentation?.tile.shows("join") != false
            {
                Button {
                    store.perform(.join, eventID: event.id)
                } label: {
                    EdithIconView(.video)
                }
                .buttonStyle(.edith(.iconOnly, tint: theme))
                .help("Join meeting")
                .accessibilityLabel("Join meeting")
            }
        }
        .frame(minHeight: UIScale.pt(36))
    }

    private func timeLabel(_ event: CalendarEventPayload) -> String {
        guard !event.isAllDay else { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }
}

private struct CalendarTrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: UIScale.pt(4)) {
            configuration.title
            configuration.icon.imageScale(.small)
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
