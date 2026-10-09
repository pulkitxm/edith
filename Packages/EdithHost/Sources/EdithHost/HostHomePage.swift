import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import Foundation
import SwiftUI

struct HostHomePage: View {
    let marketplace: HostMarketplace
    let customize: () -> Void
    let extensions: () -> Void
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let layout = marketplace.surfaceAvailability.projected(
            marketplace.surfaceLayouts.home, target: .home)
        PageScaffold(width: .fluid) {
            PageHeader("Home") {
                Button("Customize", action: customize).buttonStyle(.edith(.secondary))
                Button("Extensions", action: extensions).buttonStyle(.edith(.secondary))
            }
        } content: {
            SurfaceCanvas(layout: layout, singleColumn: compact) { tile in
                HostSurfaceCard(marketplace: marketplace, target: .home, tile: tile)
            }
            if marketplace.surfaceAvailability.activeIDs.isEmpty {
                Text("Download and enable extensions to add their widgets to Home.")
                    .font(.edithText(.callout)).foregroundStyle(.secondary)
            }
        }
    }
}

struct HostSurfaceCard: View {
    let marketplace: HostMarketplace
    let target: SurfaceTarget
    let tile: SurfaceTile
    @Environment(\.surfacePresentation) private var presentation
    @Environment(\.surfaceFillHeight) private var fillHeight

    private var providers: [HostExtension] {
        marketplace.entries.filter {
            tile.widget.providerIDs.contains($0.id)
                && marketplace.surfaceAvailability.activeIDs.contains($0.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(tile.dense ? 8 : 12)) {
            if tile.showTitle {
                Label(title, systemImage: tile.widget.icon).font(.edithText(.headline))
                    .accessibilityLabel(title)
            }
            if tile.widget == .clocks {
                HostClockCard(tile: tile)
            } else {
                ForEach(providers) { provider in
                    HostSurfaceProviderCard(
                        marketplace: marketplace, provider: provider, target: target, tile: tile,
                        showProvider: providers.count > 1)
                }
            }
        }
        .padding(UIScale.pt(presentation?.padding ?? (tile.dense ? 10 : 14)))
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: UIScale.pt(presentation?.cornerRadius ?? 14)))
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

private struct HostClockCard: View {
    let tile: SurfaceTile
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            Text(now.formatted(date: .omitted, time: .shortened)).font(.edithText(.title2))
                .monospacedDigit()
            if tile.showDetails {
                Text("Local time").font(.edithText(.caption)).foregroundStyle(.secondary)
            }
        }
        .pageRefresh(interval: { .seconds(60) }) { now = Date() }
    }
}

private struct HostSurfaceProviderCard: View {
    let marketplace: HostMarketplace
    let provider: HostExtension
    let target: SurfaceTarget
    let tile: SurfaceTile
    let showProvider: Bool
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
                    Button("Open") { Task { await marketplace.show(id: provider.id) } }
                        .accessibilityLabel("Open " + provider.title)
                }
            }.buttonStyle(.edith(.borderless))
            if hidden {
                Label("Hidden while presenting", systemImage: "eye.slash").font(
                    .edithText(.caption)
                ).foregroundStyle(.secondary)
            } else if let snapshot {
                SurfaceSnapshotContent(tile: tile, snapshot: snapshot, perform: perform)
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
        guard !hidden, actionTask == nil, let snapshot else { return }
        actionError = nil
        let token = UUID()
        actionToken = token
        actionTask = Task {
            defer { if actionToken == token { actionTask = nil; actionToken = nil } }
            do {
                let next = try await marketplace.surfaces.requests.perform(
                    providerID: provider.id, target: target, tile: tile, snapshot: snapshot,
                    actionID: action.id)
                try Task.checkCancellation()
                self.snapshot = next
            } catch {
                guard !Task.isCancelled else { return }
                actionError = error.localizedDescription
            }
        }
    }
}
