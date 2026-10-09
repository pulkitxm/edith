import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct NotchHomeTab: View {
    let controller: NotchShelfController
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
                ) { tile in NotchSurfaceCard(controller: controller, tile: tile) }
            } else {
                ScrollView {
                    SurfaceCanvas(
                        layout: layout, singleColumn: false, editing: controller.layoutEditing,
                        selected: selected, select: { selected = $0 },
                        place: { widget, _ in add(widget) },
                        inspect: { controller.openCustomization(tileID: $0) }, reorder: reorder,
                        configure: configure
                    ) { tile in NotchSurfaceCard(controller: controller, tile: tile) }
                }
            }
        }.padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func reorder(_ id: String, _ before: String?) {
        controller.layouts.update(.notch) { $0.move(id, before: before) }
    }

    private func configure(_ tile: SurfaceTile) {
        controller.layouts.update(.notch) { layout in
            if let index = layout.tiles.firstIndex(where: { $0.id == tile.id }) {
                layout.tiles[index] = tile
            }
        }
    }

    private func add(_ widget: SurfaceWidget) {
        controller.layouts.update(.notch) { _ = $0.add(widget) }
    }
}

struct NotchSurfaceCard: View {
    let controller: NotchShelfController
    let tile: SurfaceTile
    @Environment(\.surfacePresentation) private var presentation

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            if tile.showTitle {
                Label(tile.displayTitle, systemImage: tile.widget.icon).font(.edithText(.headline))
            }
            if tile.widget == .clocks {
                SurfaceWorldClocks(tile: tile, defaults: controller.context.defaults)
            } else {
                ForEach(
                    tile.widget.providerIDs.intersection(controller.activeIDs).sorted(), id: \.self
                ) { id in
                    NotchProviderCard(controller: controller, providerID: id, tile: tile)
                }
            }
        }.padding(UIScale.pt(presentation?.padding ?? 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: UIScale.pt(presentation?.cornerRadius ?? 12)))
    }
}

private struct NotchProviderCard: View {
    let controller: NotchShelfController
    let providerID: String
    let tile: SurfaceTile
    @State private var snapshot: SurfaceSnapshot?
    @State private var load = ContentLoad()
    @State private var retry = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var actionToken: UUID?
    @State private var actionError: String?

    private var hidden: Bool { controller.privacy.hides(tile.widget) }
    private var version: String? { controller.requests.versions[providerID] }

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
                        try await controller.requests.snapshot(
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
                let next = try await controller.requests.perform(
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
