import EdithExtensionSupport
import SwiftUI

public struct SurfaceShelf<Content: View>: View {
    let layout: SurfaceLayout
    let editing: Bool
    let selected: String?
    let select: (String) -> Void
    let inspect: (String) -> Void
    let reorder: (String, String?) -> Void
    let configure: (SurfaceTile) -> Void
    let add: (SurfaceWidget) -> Void
    let measuredHeight: (Double) -> Void
    let content: (SurfaceTile) -> Content
    @State private var focused: String?
    @State private var frames: [String: CGRect] = [:]
    @State private var viewportWidth = 600.0

    private var widths: [Double] {
        SurfaceArrangement.shelfWidths(
            tiles: layout.visible, available: max(160, viewportWidth - 4),
            preferred: layout.notchCardWidth, gap: layout.gap)
    }

    public init(
        layout: SurfaceLayout, editing: Bool = false, selected: String? = nil,
        select: @escaping (String) -> Void = { _ in },
        inspect: @escaping (String) -> Void = { _ in },
        reorder: @escaping (String, String?) -> Void = { _, _ in },
        configure: @escaping (SurfaceTile) -> Void = { _ in },
        add: @escaping (SurfaceWidget) -> Void = { _ in },
        measuredHeight: @escaping (Double) -> Void = { _ in },
        @ViewBuilder content: @escaping (SurfaceTile) -> Content
    ) {
        self.layout = layout
        self.editing = editing
        self.selected = selected
        self.select = select
        self.inspect = inspect
        self.reorder = reorder
        self.configure = configure
        self.add = add
        self.measuredHeight = measuredHeight
        self.content = content
    }

    private var index: Int {
        layout.visible.firstIndex { $0.id == focused } ?? 0
    }

    public var body: some View {
        ScrollViewReader { reader in
            VStack(spacing: UIScale.pt(8)) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: UIScale.pt(layout.gap)) {
                        ForEach(Array(layout.visible.enumerated()), id: \.element.id) {
                            index, tile in
                            SurfaceShelfTile(
                                tile: tile, layout: layout, fittedWidth: widths[index],
                                editing: editing,
                                selected: selected == tile.id, select: { select(tile.id) },
                                inspect: { inspect(tile.id) },
                                measured: { frame in
                                    frames[tile.id] = frame
                                    focused =
                                        frames.filter { pair in
                                            layout.visible.contains { $0.id == pair.key }
                                        }.min { abs($0.value.minX) < abs($1.value.minX) }?.key
                                },
                                move: { x in
                                    let anchor = frames.filter {
                                        $0.key != tile.id && $0.value.midX > x
                                    }.min { $0.value.minX < $1.value.minX }?.key
                                    reorder(tile.id, anchor)
                                    focused = tile.id
                                }, configure: configure
                            ) {
                                content(tile).environment(
                                    \.surfacePresentation,
                                    SurfacePresentation(tile: tile, layout: layout)
                                ).tint(tile.highlightColor)
                            }
                            .id(tile.id)
                        }
                        if editing {
                            Label("Drop a widget", systemImage: "plus.circle")
                                .font(.edithText(.caption))
                                .foregroundStyle(.secondary)
                                .frame(width: UIScale.pt(120), height: UIScale.pt(100))
                                .background(
                                    Color.accentColor.opacity(0.06),
                                    in: RoundedRectangle(
                                        cornerRadius: UIScale.pt(layout.cornerRadius))
                                )
                        }
                    }
                    .padding(UIScale.pt(2))
                    .background(SurfaceShelfWheelRouter())
                }
                .frame(
                    height: UIScale.pt(
                        max(
                            editing ? 100 : 0,
                            frames.values.map { Double($0.height) }.max() ?? layout.notchShelfHeight
                        ) + 4)
                )
                .coordinateSpace(name: "surfaceShelf")
                .onGeometryChange(for: Double.self) {
                    $0.size.width / UIScale.current
                } action: {
                    viewportWidth = $0
                }
                .onDrop(
                    of: [SurfaceDrag.type], delegate: SurfaceShelfDrop(enabled: editing, add: add)
                )
                .scrollIndicators(.hidden)
                .onChange(of: selected) { _, value in
                    if let value { focused = value }
                }
                .onChange(of: layout.visible.count) { _, _ in
                    if let selected { reader.scrollTo(selected, anchor: .leading) }
                }
                HStack(spacing: UIScale.pt(10)) {
                    Button {
                        browse(-1, reader: reader)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(index == 0).accessibilityLabel("Previous widget")
                    Text(
                        layout.visible.isEmpty
                            ? "No widgets" : "\(index + 1) / \(layout.visible.count)"
                    )
                    .monospacedDigit()
                    Button {
                        browse(1, reader: reader)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(index >= layout.visible.count - 1).accessibilityLabel("Next widget")
                    Spacer(minLength: 0)
                    Text(
                        editing
                            ? "Drag a handle to reorder. Resize from the corner."
                            : "Scroll to browse"
                    )
                    .foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.edithText(.caption)).buttonStyle(.edith(.borderless))
            }
            .onGeometryChange(for: Double.self) {
                $0.size.height / UIScale.current
            } action: {
                measuredHeight($0)
            }
        }
    }

    private func browse(_ offset: Int, reader: ScrollViewProxy) {
        let destination = min(max(0, index + offset), layout.visible.count - 1)
        guard layout.visible.indices.contains(destination) else { return }
        focused = layout.visible[destination].id
        withAnimation(.easeInOut(duration: 0.2)) { reader.scrollTo(focused, anchor: .leading) }
    }
}

private struct SurfaceShelfDrop: DropDelegate {
    let enabled: Bool
    let add: @MainActor (SurfaceWidget) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [SurfaceDrag.type])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        guard enabled else { return false }
        return SurfaceDrag.accept(info.itemProviders(for: [SurfaceDrag.type]), perform: add)
    }
}

private struct SurfaceShelfTile<Content: View>: View {
    let tile: SurfaceTile
    let layout: SurfaceLayout
    let fittedWidth: Double
    let editing: Bool
    let selected: Bool
    let select: () -> Void
    let inspect: () -> Void
    let measured: (CGRect) -> Void
    let move: (Double) -> Void
    let configure: (SurfaceTile) -> Void
    @ViewBuilder let content: () -> Content
    @State private var frame = CGRect.zero
    @State private var movement = CGFloat.zero
    @State private var sizing = CGSize.zero
    @State private var sizingOrigin: CGSize?
    @State private var contentHeight = 100.0

    private var width: Double {
        sizingOrigin.map { Double($0.width) } ?? tile.shelfWidth ?? fittedWidth
    }
    private var height: Double {
        sizingOrigin.map { Double($0.height) } ?? tile.height
            ?? layout.notchShelfHeight
    }

    var body: some View {
        VStack(spacing: UIScale.pt(6)) {
            if editing {
                HStack {
                    Image(systemName: tile.locked ? "lock.fill" : "line.3.horizontal")
                    Text(tile.displayTitle).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(Int(width)) pt").foregroundStyle(.secondary)
                }
                .font(.edithText(.caption)).padding(.horizontal, UIScale.pt(8))
                .padding(.top, UIScale.pt(8)).contentShape(Rectangle())
                .onTapGesture(perform: select)
                .highPriorityGesture(
                    DragGesture(
                        minimumDistance: tile.locked ? .infinity : 3, coordinateSpace: .global
                    )
                    .onChanged { value in
                        select(); movement = value.translation.width
                    }
                    .onEnded { value in
                        move((frame.midX + value.translation.width) / UIScale.current)
                        movement = 0
                    }
                )
                .accessibilityLabel("Reorder \(tile.displayTitle)")
            }
            ScrollView {
                content().frame(
                    maxWidth: .infinity, minHeight: UIScale.pt(height), alignment: .topLeading
                )
                .environment(\.surfaceFillHeight, true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Double.self) {
                    $0.size.height / UIScale.current
                } action: {
                    contentHeight = $0
                }
                .disabled(editing).allowsHitTesting(!editing)
            }
            .frame(height: UIScale.pt(min(600, max(64, height + sizing.height / UIScale.current))))
            if editing {
                HStack {
                    Button("Configure", action: inspect)
                        .buttonStyle(.edith(.secondary))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .padding(UIScale.pt(6)).contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(
                                minimumDistance: tile.locked ? .infinity : 2,
                                coordinateSpace: .global
                            )
                            .onChanged { value in
                                if sizingOrigin == nil {
                                    sizingOrigin = CGSize(width: width, height: height)
                                }
                                select(); sizing = value.translation
                            }
                            .onEnded { value in
                                var changed = tile
                                changed.shelfWidth = min(
                                    760,
                                    max(160, width + value.translation.width / UIScale.current))
                                changed.height = min(
                                    600,
                                    max(64, height + value.translation.height / UIScale.current)
                                )
                                configure(changed)
                                sizing = .zero
                                sizingOrigin = nil
                            }
                        )
                        .accessibilityLabel("Resize \(tile.displayTitle)")
                }
                .font(.edithText(.caption)).padding(.horizontal, UIScale.pt(8))
                .padding(.bottom, UIScale.pt(6))
            }
        }
        .frame(
            width: UIScale.pt(
                min(
                    tile.shelfWidth == nil ? 1200 : 760,
                    max(160, width + sizing.width / UIScale.current)))
        )
        .background(
            Color.secondary.opacity(editing ? 0.045 : 0),
            in: RoundedRectangle(cornerRadius: UIScale.pt(layout.cornerRadius))
        )
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: UIScale.pt(layout.cornerRadius))
                    .stroke(
                        selected ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: selected ? 2 : 1)
            }
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("surfaceShelf"))
        } action: {
            if movement == 0 && sizing == .zero {
                frame = $0
                measured(
                    CGRect(
                        x: $0.minX / UIScale.current, y: $0.minY / UIScale.current,
                        width: $0.width / UIScale.current, height: $0.height / UIScale.current))
            }
        }
        .offset(x: movement).zIndex(movement == 0 ? 0 : 1)
    }
}
