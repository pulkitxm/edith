import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct NotchHomeTab: View {
    let controller: NotchShelfController
    @State private var selected: String?

    private var layout: SurfaceLayout {
        var value = controller.surfaceLayout
        value.tiles = value.visible.filter { $0.widget.available(activeIDs: controller.activeIDs) }
        return value
    }

    var body: some View {
        Group {
            if layout.notchHorizontal {
                SurfaceShelf(
                    layout: layout, editing: controller.layoutEditing, selected: selected,
                    select: { selected = $0 }, inspect: { _ in controller.openCustomization() },
                    reorder: reorder, configure: configure, add: add,
                    measuredHeight: controller.measureHomeContent
                ) { tile in NotchSurfaceCard(controller: controller, tile: tile) }
            } else {
                ScrollView {
                    SurfaceCanvas(
                        layout: layout, singleColumn: false, editing: controller.layoutEditing,
                        selected: selected, select: { selected = $0 },
                        place: { widget, _ in add(widget) },
                        inspect: { _ in controller.openCustomization() }, reorder: reorder,
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
        controller.layouts.update(.notch) { $0.tiles.append(SurfaceTile(widget)) }
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
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.edithText(.title2)).monospacedDigit()
                }
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
                SurfaceSnapshotContent(tile: tile, snapshot: snapshot, perform: perform)
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
        guard !hidden, actionTask == nil, let snapshot else { return }
        let token = UUID()
        actionToken = token
        actionTask = Task {
            defer { if actionToken == token { actionTask = nil; actionToken = nil } }
            do {
                let value = try await controller.requests.perform(
                    providerID: providerID, target: .notch, tile: tile, snapshot: snapshot,
                    actionID: action.id)
                try Task.checkCancellation()
                self.snapshot = value
            } catch {
                if !Task.isCancelled { actionError = error.localizedDescription }
            }
        }
    }
}
