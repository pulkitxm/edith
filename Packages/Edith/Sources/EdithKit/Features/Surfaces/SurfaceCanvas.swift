import SwiftUI
import UniformTypeIdentifiers

public enum SurfaceDrag {
    public static let prefix = "edith-surface:"
    public static func provider(_ widget: SurfaceWidget) -> NSItemProvider {
        NSItemProvider(object: (prefix + widget.id) as NSString)
    }
    public static func accept(
        _ providers: [NSItemProvider], perform: @escaping @MainActor (SurfaceWidget) -> Void
    ) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let token = object as? String, token.hasPrefix(prefix),
                let widget = SurfaceWidget(rawValue: String(token.dropFirst(prefix.count)))
            else { return }
            Task { @MainActor in perform(widget) }
        }
        return true
    }
}

public struct SurfaceCanvas<Content: View>: View {
    let layout: SurfaceLayout
    let singleColumn: Bool
    let editing: Bool
    let selected: String?
    let select: (String) -> Void
    let place: (SurfaceWidget, String?) -> Void
    let resize: (String, SurfaceWidgetSize) -> Void
    let content: (SurfaceTile) -> Content

    public init(
        layout: SurfaceLayout, singleColumn: Bool, editing: Bool = false, selected: String? = nil,
        select: @escaping (String) -> Void = { _ in },
        place: @escaping (SurfaceWidget, String?) -> Void = { _, _ in },
        resize: @escaping (String, SurfaceWidgetSize) -> Void = { _, _ in },
        @ViewBuilder content: @escaping (SurfaceTile) -> Content
    ) {
        self.layout = layout
        self.singleColumn = singleColumn
        self.editing = editing
        self.selected = selected
        self.select = select
        self.place = place
        self.resize = resize
        self.content = content
    }

    public var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            ForEach(Array(layout.rows(singleColumn: singleColumn).enumerated()), id: \.offset) {
                _, row in
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    ForEach(row) { tile in
                        SurfaceCanvasTile(
                            tile: tile, editing: editing, selected: selected == tile.id,
                            select: { select(tile.id) }, place: { place($0, tile.id) },
                            resize: { resize(tile.id, $0) }
                        ) { content(tile) }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    if row.count == 1, !singleColumn, !row[0].size.spansRow {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
            if editing {
                SurfaceDropWell(empty: layout.visible.isEmpty) { place($0, nil) }
            }
        }
    }
}

private struct SurfaceCanvasTile<Content: View>: View {
    let tile: SurfaceTile
    let editing: Bool
    let selected: Bool
    let select: () -> Void
    let place: (SurfaceWidget) -> Void
    let resize: (SurfaceWidgetSize) -> Void
    @ViewBuilder let content: () -> Content
    @State private var targeted = false
    @State private var resizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            if editing {
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .onDrag { SurfaceDrag.provider(tile.widget) }
                        .help("Drag to move \(tile.displayTitle)")
                        .accessibilityLabel("Move \(tile.displayTitle)")
                    Text(tile.displayTitle).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(tile.size.title).foregroundStyle(.secondary)
                }
                .font(.edithText(.caption))
                .padding(.horizontal, UIScale.pt(10)).padding(.top, UIScale.pt(8))
                .contentShape(Rectangle())
                .onTapGesture(perform: select)
            }
            content().allowsHitTesting(!editing)
            if editing {
                HStack {
                    Button("Configure", action: select).font(.edithText(.caption))
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.edithText(.caption)).foregroundStyle(
                            resizing ? Color.accentColor : .secondary
                        )
                        .frame(width: UIScale.pt(28), height: UIScale.pt(22))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { _ in resizing = true }
                                .onEnded { drag in
                                    resizing = false
                                    if abs(drag.translation.width) > 35 {
                                        resize(drag.translation.width > 0 ? .wide : .regular)
                                    } else if abs(drag.translation.height) > 20 {
                                        resize(drag.translation.height > 0 ? .regular : .compact)
                                    }
                                }
                        )
                        .help(
                            "Drag right for full width, left for half width, up for compact, down for regular"
                        )
                }
                .padding(.horizontal, UIScale.pt(10)).padding(.bottom, UIScale.pt(6))
            }
        }
        .background {
            if editing {
                RoundedRectangle(cornerRadius: UIScale.pt(12)).fill(
                    Color.accentColor.opacity(selected ? 0.08 : 0.025))
            }
        }
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: UIScale.pt(12))
                    .strokeBorder(
                        targeted || selected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: targeted ? 3 : 1
                    )
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if targeted { Capsule().fill(Color.accentColor).frame(height: 4).offset(y: -6) }
        }
        .onDrop(of: [.text], isTargeted: $targeted) { providers in
            editing && SurfaceDrag.accept(providers, perform: place)
        }
    }
}

private struct SurfaceDropWell: View {
    let empty: Bool
    let place: (SurfaceWidget) -> Void
    @State private var targeted = false
    var body: some View {
        Label(
            empty ? "Drop your first widget here" : "Drop here to add at the end",
            systemImage: "plus.circle"
        )
        .font(.edithText(.caption)).foregroundStyle(targeted ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity).padding(UIScale.pt(empty ? 32 : 16))
        .background(
            Color.accentColor.opacity(targeted ? 0.1 : 0.025),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .onDrop(of: [.text], isTargeted: $targeted) { SurfaceDrag.accept($0, perform: place) }
    }
}

public enum SurfaceTabDrag {
    public static func accept(
        _ providers: [NSItemProvider], perform: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let prefix = "edith-notch-tab:"
            guard let token = object as? String, token.hasPrefix(prefix),
                let tab = SurfaceNotchTab(rawValue: String(token.dropFirst(prefix.count)))
            else { return }
            Task { @MainActor in perform(tab.rawValue) }
        }
        return true
    }
}
