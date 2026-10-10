import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct NotchSlotFrames: PreferenceKey {
    static var defaultValue: [NotchPanelSlot] = []
    static func reduce(value: inout [NotchPanelSlot], nextValue: () -> [NotchPanelSlot]) {
        value.append(contentsOf: nextValue())
    }
}

private struct NotchSlotViewportKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    var notchSlotViewport: CGRect? {
        get { self[NotchSlotViewportKey.self] }
        set { self[NotchSlotViewportKey.self] = newValue }
    }
}

struct NotchSlotViewport<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            content().environment(\.notchSlotViewport, geometry.frame(in: .named("notchPanel")))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct NotchNativeSlotView: View {
    let client: NotchChromeClient
    let tile: SurfaceTile
    let kind: NotchPanelSlot.Kind
    @Environment(\.notchSlotViewport) private var viewport
    private var fallbackHeight: Double {
        switch kind {
        case .collapsedLeading, .collapsedTrailing: client.snapshot?.display.collapsedHeight ?? 28
        case .header: 24
        case .providerTab: tile.height ?? 240
        case .card:
            tile.height ?? (tile.widget == .music ? (tile.dense ? 62 : 92) : 160)
        }
    }
    var body: some View {
        Color.clear
            .frame(minHeight: client.slotHeight(tile: tile, kind: kind) ?? fallbackHeight)
            .overlay {
                if let failure = client.slotFailure(tile: tile, kind: kind)
                    ?? (client.supportsNative(tile: tile, kind: kind)
                        ? nil : "This widget’s native surface is unavailable.")
                {
                    Text(failure).font(.edithText(.caption)).foregroundStyle(.orange)
                        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.9))
                }
            }
            .background {
                GeometryReader { geometry in
                    let rectangle = geometry.frame(in: .named("notchPanel"))
                    let clipped = viewport.map { rectangle.intersection($0) } ?? rectangle
                    let slot = client.slot(tile: tile, kind: kind, rectangle: clipped)
                    Color.clear.preference(
                        key: NotchSlotFrames.self, value: slot.map { [$0] } ?? [])
                }
            }
    }
}

struct NotchPanelPage: View {
    let client: NotchChromeClient
    var body: some View {
        Group {
            if let snapshot = client.snapshot {
                NotchShelfContentView(
                    controller: client, displayID: client.displayID,
                    collapsedBase: snapshot.display.collapsedSize,
                    isBuiltin: snapshot.display.isBuiltin
                )
                .coordinateSpace(name: "notchPanel")
                .onPreferenceChange(NotchSlotFrames.self) { client.report($0) }
            } else if let error = client.error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.orange).padding(12)
            } else {
                Color.clear
            }
        }.task { await client.refresh() }
            .onDisappear { client.stop() }
    }
}
