import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import AppKit
import Foundation
import SwiftUI

struct HostHomePage: View {
    let marketplace: HostMarketplace
    let customize: () -> Void
    let extensions: () -> Void
    var openExtension: ((String) -> Void)? = nil
    var presenter: (any HostExtensionContentPresenting)? = nil
    @Environment(\.compactLayout) private var compact

    @State private var editing = false
    @State private var selectedTile: String?
    @Environment(\.colorScheme) private var scheme
    private var layout: SurfaceLayout {
        if editing || marketplace.surfaces.preferences.string(forKey: SurfaceTarget.home.key) != nil
        {
            return marketplace.surfaceLayouts.home
        }
        return marketplace.surfaceAvailability.projected(
            marketplace.surfaceLayouts.home, target: .home)
    }
    var body: some View {
        PageScaffold(pinnedHeader: true) {
            HostHomeHeader(
                dark: scheme == .dark, editing: $editing, layouts: marketplace.surfaceLayouts,
                customize: customize)
        } content: {
            SurfaceCanvas(
                layout: layout, singleColumn: compact, editing: editing, selected: selectedTile,
                select: { selectedTile = $0 },
                place: { widget, anchor in
                    marketplace.surfaceLayouts.update(.home) { layout in
                        let id = layout.add(widget);
                        if let anchor { layout.move(id, before: anchor) }; selectedTile = id
                    }
                },
                inspect: {
                    marketplace.surfaces.preferences.set($0, forKey: HostSurfaceEditorKeys.widget);
                    customize()
                },
                reorder: { id, anchor in
                    marketplace.surfaceLayouts.update(.home) { $0.move(id, before: anchor) }
                },
                configure: { tile in
                    marketplace.surfaceLayouts.update(.home) { layout in
                        guard let index = layout.tiles.firstIndex(where: { $0.id == tile.id })
                        else { return }
                        if compact { layout.tiles[index] = tile } else { layout.position(tile) }
                    }
                },
                placeAt: { widget, column, row in
                    marketplace.surfaceLayouts.update(.home) {
                        selectedTile = $0.add(widget, column: column, row: row)
                    }
                }
            ) { tile in
                if tile.widget != .clocks
                    && Set(tile.widget.providerIDs).isDisjoint(
                        with: marketplace.surfaceAvailability.activeIDs)
                {
                    PageCard(title: tile.displayTitle) {
                        Text("Enable this integration in Extensions.").font(.edithText(.callout))
                            .foregroundStyle(.secondary)
                        Button("Open Extensions", action: extensions)
                    }
                } else {
                    HostSurfaceCard(
                        marketplace: marketplace, target: .home, tile: tile,
                        openExtension: openExtension, presenter: presenter)
                }
            }
            if layout.visible.isEmpty, !editing {
                ContentUnavailableView(
                    "Make yourself at home", systemImage: "rectangle.3.group",
                    description: Text("Add widgets in the Home & Notch editor."))
            }
        }.navigationTitle("Home")
    }
}

private struct HostHomeHeader: View {
    let dark: Bool
    @Binding var editing: Bool
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowVisible) private var visible
    let layouts: SurfaceLayoutStore
    let customize: () -> Void
    @Environment(\.surfaceSampleContent) private var sampleContent

    private var firstName: String {
        if sampleContent
            || ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        {
            return "Alex"
        }
        let full = NSFullUserName()
        let name = full.isEmpty ? NSUserName() : full
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private func clockString(_ now: Date) -> String {
        let cal = Calendar.current
        return String(
            format: "%d:%02d:%02d", ((cal.component(.hour, from: now) + 11) % 12) + 1,
            cal.component(.minute, from: now), cal.component(.second, from: now))
    }

    private func salutation(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Up late"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: visible ? 1 : 60)) { context in
            let now = context.date
            PageHeader {
                greeting(now)
            } trailing: {
                HStack(spacing: UIScale.pt(16)) {
                    if !compact { clockBlock(now, alignment: .trailing) }
                    layoutControls
                }
            } accessory: {
                subtitle(now)
                if compact { clockBlock(now, alignment: .leading) }
                if editing {
                    Text("Drag a widget handle to place it. Drag a corner to resize.")
                        .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var layoutControls: some View {
        HStack(spacing: UIScale.pt(8)) {
            Button("Auto fit") {
                layouts.update(.home) {
                    $0.arrangeAutomatically()
                    $0.balancedRows = true
                }
            }
            Button(editing ? "Done" : "Edit layout") { editing.toggle() }
            Button("Widget editor") { customize() }
        }
        .font(.edithText(.caption))
        .buttonStyle(.edith(.secondary))
    }

    private func greeting(_ now: Date) -> some View {
        (Text("\(salutation(now)), ")
            + Text(firstName).italic().foregroundColor(DashSkin.accentDeep(dark))
            + Text("."))
    }

    private func subtitle(_ now: Date) -> some View {
        Text(
            now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
                .uppercased()
        )
        .font(DashSkin.mono(11)).tracking(UIScale.pt(1.6))
        .foregroundStyle(DashSkin.inkFaint(dark))
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func clockText(_ date: Date) -> some View {
        Text(clockString(date))
            .font(PageMetrics.titleFont(compact))
            .foregroundStyle(DashSkin.ink(dark))
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
    }

    private func clockBlock(_ now: Date, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: UIScale.pt(2)) {
            clockText(now)
            Text(
                "\(Calendar.current.component(.hour, from: now) < 12 ? "AM" : "PM")"
                    + " · \(TimeZone.current.abbreviation() ?? "local")"
            )
            .font(DashSkin.mono(11)).tracking(UIScale.pt(1.2))
            .foregroundStyle(DashSkin.inkFaint(dark))
        }
    }
}

struct HostSurfaceCard: View {
    let marketplace: HostMarketplace
    let target: SurfaceTarget
    let tile: SurfaceTile
    var openExtension: ((String) -> Void)? = nil
    var presenter: (any HostExtensionContentPresenting)? = nil
    @Environment(\.surfaceFillHeight) private var fillHeight
    @Environment(\.compactLayout) private var compact

    private var providers: [HostExtension] {
        marketplace.entries.filter {
            tile.widget.providerIDs.contains($0.id)
                && marketplace.surfaceAvailability.activeIDs.contains($0.id)
        }
    }

    var body: some View {
        Group {
            if let presenter, !marketplace.surfaces.privacy.hides(tile.widget),
                providers.count == 1, let provider = providers.first,
                let section = HostNativeSurfaceRoute.section(
                    provider: provider.id, target: target, tile: tile)
            {
                HostExtensionContent(
                    marketplace: marketplace, extensionID: provider.id, location: "home",
                    section: section, presenter: presenter,
                    openMarketplace: { openExtension?(provider.id) },
                    surface: SurfaceSnapshotRequest(target: target, tile: tile))
            } else {
                genericCard
            }
        }
        .environment(\.compactLayout, compact || tile.dense)
    }

    private var genericCard: some View {
        PageCard(
            title: tile.showTitle ? title : nil,
            note: tile.widget == .clocks ? "hover a clock to remove" : nil,
            fill: fillHeight
        ) {
            if tile.widget == .clocks {
                SurfaceWorldClocks(tile: tile, defaults: marketplace.surfaces.preferences)
            } else {
                ForEach(providers) { provider in
                    HostSurfaceProviderCard(
                        marketplace: marketplace, provider: provider,
                        target: target, tile: tile, showProvider: providers.count > 1,
                        openExtension: openExtension)
                }
            }
        }
    }

    private var title: String {
        if !tile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tile.displayTitle
        }
        if case .ability(let id) = tile.widget {
            return marketplace.entries.first { $0.id == id }?.title ?? tile.widget.title
        }
        return tile.widget.title
    }
}

private struct HostSurfaceProviderCard: View {
    let marketplace: HostMarketplace
    let provider: HostExtension
    let target: SurfaceTarget
    let tile: SurfaceTile
    let showProvider: Bool
    var openExtension: ((String) -> Void)? = nil
    @State private var snapshot: SurfaceSnapshot?
    @State private var load = ContentLoad()
    @State private var retry = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var actionError: String?
    @State private var actionToken: UUID?

    private var version: String? {
        marketplace.surfaceAvailability.activeIDs.contains(provider.id)
            ? marketplace.sessions.versions[provider.id] : nil
    }

    private var hidden: Bool { marketplace.surfaces.privacy.hides(tile.widget) }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack {
                if showProvider {
                    Label(provider.title, systemImage: provider.symbolName).font(
                        .edithText(.callout))
                }
                Spacer(minLength: 0)
                if tile.showActions {
                    Button {
                        retry += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh " + provider.title)
                    if let openExtension {
                        Button("Open") { openExtension(provider.id) }
                            .accessibilityLabel("Open " + provider.title)
                    }
                }
            }.buttonStyle(.edith(.borderless))
            if hidden {
                Label("Hidden while presenting", systemImage: "eye.slash").font(
                    .edithText(.caption)
                ).foregroundStyle(.secondary)
            } else if let snapshot {
                SurfaceSnapshotContent(
                    tile: tile, snapshot: snapshot, perform: perform, adjust: adjust
                )
                .disabled(actionTask != nil)
            } else if load.isRunning {
                LoadingIndicator()
            }
            if let error = actionError ?? load.errorMessage {
                Text(error).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry") { retry += 1 }.buttonStyle(.edith(.secondary))
            }
        }
        .pageTask(
            id: Request(tile: tile, version: version, retry: retry),
            active: version != nil && !hidden
                && (target != .notch
                    || marketplace.surfaceAvailability.activeIDs.contains("notchShelf")),
            cancel: clear
        ) {
            repeat {
                let requests = marketplace.surfaces.requests
                await load.perform(
                    operation: {
                        try await requests.snapshot(
                            providerID: provider.id, target: target, tile: tile)
                    }, apply: { snapshot = $0 })
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: interval) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: version) { clear() }
        .onChange(of: hidden) { clear() }
        .onDisappear(perform: clear)
    }

    private struct Request: Equatable {
        let tile: SurfaceTile
        let version: String?
        let retry: Int
    }

    private var interval: Duration {
        switch provider.id {
        case "systemStats", "system": .seconds(2)
        case "downloads", "audioMixer", "timeLapse": .seconds(5)
        case "clipboard", "notchShelf": .seconds(10)
        default: .seconds(30)
        }
    }

    private func clear() {
        actionTask?.cancel(); actionTask = nil; actionToken = nil
        load.reset(); snapshot = nil; actionError = nil
    }

    private func perform(_ action: SurfaceAction) {
        execute(actionID: action.id)
    }

    private func adjust(_ slider: SurfaceSlider, _ value: Double) {
        execute(actionID: slider.id, value: value)
    }

    private func execute(actionID: String, value: Double? = nil) {
        guard !hidden, actionTask == nil, let snapshot else { return }
        actionError = nil
        let token = UUID()
        actionToken = token
        actionTask = Task {
            defer { if actionToken == token { actionTask = nil; actionToken = nil } }
            do {
                let next = try await marketplace.surfaces.requests.perform(
                    providerID: provider.id, target: target, tile: tile, snapshot: snapshot,
                    actionID: actionID, value: value)
                try Task.checkCancellation()
                self.snapshot = next
            } catch {
                guard !Task.isCancelled else { return }
                actionError = error.localizedDescription
            }
        }
    }
}
