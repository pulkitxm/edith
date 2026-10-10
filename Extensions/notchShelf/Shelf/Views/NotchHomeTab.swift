import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct NotchHomeTab: View {
    let controller: any NotchChromeFacade
    @State private var selected: String?

    private var layout: SurfaceLayout { controller.visibleSurfaceLayout }

    var body: some View {
        Group {
            if layout.visible.isEmpty {
                VStack(spacing: UIScale.pt(12)) {
                    Text("Enable extensions to add their widgets to the Notch.").font(
                        .edithText(.callout))
                    Button("Customize") { controller.openCustomization() }.buttonStyle(
                        .edith(.secondary))
                }.padding(UIScale.pt(24))
            } else if layout.notchHorizontal {
                SurfaceShelf(
                    layout: layout, editing: controller.layoutEditing, selected: selected,
                    select: { selected = $0 },
                    inspect: { controller.openCustomization(tileID: $0) },
                    reorder: reorder, configure: configure, add: add,
                    measuredHeight: controller.measureHomeContent
                ) { tile in tileContent(tile) }
            } else {
                ScrollView {
                    SurfaceCanvas(
                        layout: layout, singleColumn: false, editing: controller.layoutEditing,
                        selected: selected, select: { selected = $0 },
                        place: { widget, _ in add(widget) },
                        inspect: { controller.openCustomization(tileID: $0) }, reorder: reorder,
                        configure: { tile in
                            controller.chromeLayouts.update(.notch) { $0.position(tile) }
                        },
                        placeAt: { widget, column, row in
                            controller.chromeLayouts.update(.notch) {
                                selected = $0.add(widget, column: column, row: row)
                            }
                        }
                    ) { tile in tileContent(tile) }
                }
            }
        }.environment(\.colorScheme, .dark)
            .padding(.horizontal, 16).padding(.bottom, 14)
    }

    private func tileContent(_ tile: SurfaceTile) -> some View {
        NotchSurfaceCard(controller: controller, tile: tile)
            .contextMenu {
                Button("Move to first") {
                    controller.chromeLayouts.update(.notch) {
                        $0.move(tile.id, before: $0.visible.first?.id)
                    }
                }.disabled(tile.locked)
                Button(tile.locked ? "Unlock layout" : "Lock layout") {
                    controller.chromeLayouts.update(.notch) { layout in
                        guard let index = layout.tiles.firstIndex(where: { $0.id == tile.id })
                        else { return }
                        layout.tiles[index].locked.toggle()
                    }
                }
                Button("Duplicate") {
                    controller.chromeLayouts.update(.notch) { selected = $0.duplicate(tile.id) }
                }
                Button("Hide") {
                    controller.chromeLayouts.update(.notch) { layout in
                        guard let index = layout.tiles.firstIndex(where: { $0.id == tile.id })
                        else { return }
                        layout.tiles[index].hidden = true
                    }
                }
                Button("Open widget editor") { controller.openCustomization(tileID: tile.id) }
            }
    }

    private func reorder(_ id: String, _ before: String?) {
        controller.chromeLayouts.update(.notch) { $0.move(id, before: before) }
    }

    private func configure(_ tile: SurfaceTile) {
        controller.chromeLayouts.update(.notch) { layout in
            if let index = layout.tiles.firstIndex(where: { $0.id == tile.id }) {
                layout.tiles[index] = tile
            }
        }
    }

    private func add(_ widget: SurfaceWidget) {
        controller.chromeLayouts.update(.notch) { selected = $0.add(widget) }
    }
}

struct NotchSurfaceCard: View {
    let controller: any NotchChromeFacade
    let tile: SurfaceTile
    @Environment(\.surfacePresentation) private var presentation

    var body: some View {
        if let client = controller as? NotchChromeClient, tile.widget != .clocks {
            if tile.widget == .actions {
                NotchQuickActionsView(client: client, tile: tile)
            } else if NotchPanelSlot.supportsSharedCard(tile.widget)
                || tile.widget.providerIDs.count == 1
            {
                NotchNativeSlotView(client: client, tile: tile, kind: .card)
            } else {
                Text("This widget's native surface is unavailable.")
                    .font(.edithText(.caption)).foregroundStyle(.orange).padding(12)
            }
        } else if tile.widget == .clocks {
            NotchClockCard(tile: tile)
        } else {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                if tile.showTitle {
                    Label(tile.displayTitle, systemImage: tile.widget.icon).font(
                        .edithText(.headline))
                }
                ForEach(
                    tile.widget.providerIDs.intersection(controller.activeIDs).sorted(), id: \.self
                ) { id in
                    NotchProviderCard(controller: controller, providerID: id, tile: tile)
                }
            }.padding(UIScale.pt(presentation?.padding ?? 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(presentation?.cornerRadius ?? 12))
                )
        }
    }
}

private struct NotchClockCard: View {
    let tile: SurfaceTile
    @Environment(\.surfacePresentation) private var presentation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                if tile.showTitle {
                    Label(tile.displayTitle, systemImage: "clock")
                        .font(.edithText(.caption).weight(.semibold))
                }
                Text(context.date.formatted(.dateTime.hour().minute().second()))
                    .font(.edithText(.title2).weight(.medium)).monospacedDigit()
                if tile.showDetails, !tile.dense {
                    Text(TimeZone.current.identifier).font(.edithText(.caption2))
                        .foregroundStyle(.secondary)
                }
            }.padding(UIScale.pt(presentation?.padding ?? tile.paddingOverride ?? 14))
                .frame(maxWidth: .infinity, alignment: .leading)
        }.background(
            .white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: UIScale.pt(presentation?.cornerRadius ?? 12)))
    }
}

private struct NotchProviderCard: View {
    let controller: any NotchChromeFacade
    let providerID: String
    let tile: SurfaceTile
    @State private var snapshot: SurfaceSnapshot?
    @State private var load = ContentLoad()
    @State private var retry = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var actionToken: UUID?
    @State private var actionError: String?

    private var hidden: Bool { controller.hides(tile.widget) }
    private var version: String? { controller.surfaceClient!.versions[providerID] }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            if hidden {
                Label("Hidden while presenting", systemImage: "eye.slash").font(
                    .edithText(.caption))
            } else if let snapshot {
                SurfaceSnapshotContent(
                    tile: tile, snapshot: snapshot, perform: perform, adjust: adjust
                )
                .disabled(actionTask != nil)
            } else if load.isRunning {
                LoadingIndicator()
            }
            if let error = actionError ?? load.errorMessage {
                Text(error).font(.edithText(.caption)).lineLimit(3)
                Button("Retry") { retry += 1 }.buttonStyle(.edith(.borderless))
            }
        }.pageTask(
            id: Request(tile: tile, version: version, retry: retry),
            active: version != nil && !hidden && controller.isExpanded,
            cancel: clear
        ) {
            repeat {
                await load.perform(
                    operation: {
                        try await controller.surfaceClient!.snapshot(
                            providerID: providerID, target: .notch, tile: tile)
                    }, apply: { snapshot = $0 })
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }.onChange(of: hidden) { clear() }
            .onChange(of: version) { clear() }
            .onDisappear(perform: clear)
    }

    private struct Request: Equatable {
        let tile: SurfaceTile
        let version: String?
        let retry: Int
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
                let next = try await controller.surfaceClient!.perform(
                    providerID: providerID, target: .notch, tile: tile, snapshot: snapshot,
                    actionID: actionID, value: value)
                try Task.checkCancellation()
                self.snapshot = next
            } catch {
                if !Task.isCancelled { actionError = error.localizedDescription }
            }
        }
    }
}
