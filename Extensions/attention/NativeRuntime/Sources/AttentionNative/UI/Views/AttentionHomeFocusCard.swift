@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
import Foundation
import SwiftUI

@_implementationOnly struct AttentionHomeFocusCard: View {
    let tile: SurfaceTile
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    @Environment(\.windowVisible) private var visible
    let open: (String) -> Void
    @State private var load = ContentLoad()
    @State private var focus: AttentionFocusSession?
    @State private var error: String?
    @State private var loading = true
    @State private var retry = 0
    private var presentation: SurfacePresentation? {
        SurfacePresentation(
            tile: tile,
            layout: SurfaceHostContext.current?.layout(.home) ?? SurfaceLayout.standard(.home))
    }
    private let repository: AttentionRepository

    init(tile: SurfaceTile, repository: AttentionRepository, open: @escaping (String) -> Void) {
        self.tile = tile
        self.repository = repository
        self.open = open
    }

    var body: some View { card }

    private var card: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            if tile.showTitle || tile.showActions {
                HStack {
                    if tile.showTitle {
                        Label(tile.displayTitle, systemImage: tile.widget.icon).font(
                            .edithText(.headline)
                        )
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if tile.showActions {
                        Button {
                            open(tile.widget.destination)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .buttonStyle(.edith(.borderless)).help("Open \(tile.widget.title)")
                        .accessibilityLabel("Open \(tile.widget.title)")
                    }
                }
            }
            if let error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry") { retry += 1 }.font(.edithText(.caption))
            }
            if load.hasContent || error == nil, !loading {
                content
            } else if loading {
                LoadingIndicator()
            }
        }
        .padding(UIScale.pt(presentation?.padding ?? (tile.dense ? 10 : 14))).frame(
            maxWidth: .infinity, alignment: .leading
        )
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: UIScale.pt(presentation?.cornerRadius ?? 12))
        )
        .task(id: "\(automaticActions && visible):\(tile.widget.id):\(tile.days):\(retry)") {
            guard automaticActions && visible else {
                loading = false
                return
            }
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
    }

    @ViewBuilder private var content: some View {
        switch tile.widget {
        case .focus:
            if let focus {
                if automaticActions && visible {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        focusedContent(focus, now: context.date)
                    }
                } else {
                    focusedContent(focus, now: .now)
                }
            } else {
                HStack {
                    Text("\(tile.focusMinutes) min").font(.edithText(.title2)).monospacedDigit()
                    Spacer()
                    if tile.showActions {
                        Button("Start focus") { startFocus() }.buttonStyle(.edith(.secondary))
                    }
                }
            }
        default:
            Text(tile.widget.summary).font(.edithText(.caption)).foregroundStyle(.secondary)
            Button("Open \(tile.widget.title)") { open(tile.widget.destination) }.buttonStyle(
                .edith(.secondary))
        }
    }

    @ViewBuilder private func focusedContent(_ focus: AttentionFocusSession, now: Date) -> some View
    {
        let seconds = max(0, Int(focus.plannedDuration - now.timeIntervalSince(focus.startedAt)))
        HStack {
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.edithText(.title2)).monospacedDigit()
            Spacer()
            if tile.showActions {
                Button("Finish") { finishFocus() }.buttonStyle(.edith(.secondary))
            }
        }
        if tile.showDetails, !tile.dense, tile.shows("session") {
            Text(focus.name.isEmpty ? "Deep work" : focus.name).font(.edithText(.caption))
                .lineLimit(1)
        }
    }

    private func refresh() async {
        let request = load.begin()
        defer { if Task.isCancelled { load.cancel(request) } }
        if tile.widget == .focus { focus = repository.activeFocus() }
        error = nil
        load.complete(request)
        loading = false
    }

    private func startFocus() {
        do {
            focus = try AttentionFocusOperationExecution.start(
                name: "Deep work", duration: Double(tile.focusMinutes * 60), repository: repository)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func finishFocus() {
        do {
            try AttentionFocusOperationExecution.stop(repository: repository)
            focus = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
