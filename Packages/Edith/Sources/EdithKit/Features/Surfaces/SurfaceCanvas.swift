import SwiftUI
import UniformTypeIdentifiers

public enum SurfaceDrag {
    public static let type = UTType(exportedAs: "app.edith.surface-widget", conformingTo: .data)
    public static func provider(_ widget: SurfaceWidget) -> NSItemProvider {
        NSItemProvider(item: Data(widget.rawValue.utf8) as NSData, typeIdentifier: type.identifier)
    }
    public static func accept(
        _ providers: [NSItemProvider], perform: @escaping @MainActor (SurfaceWidget) -> Void
    ) -> Bool {
        guard
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(type.identifier)
            })
        else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, data.count < 128, let token = String(data: data, encoding: .utf8),
                let widget = SurfaceWidget(rawValue: token)
            else { return }
            Task { @MainActor in perform(widget) }
        }
        return true
    }
}

public struct SurfaceLibraryPreview: Equatable {
    public let widget: SurfaceWidget
    public let point: CGPoint
    public init(widget: SurfaceWidget, point: CGPoint) { self.widget = widget; self.point = point }
}

public struct SurfaceCanvas<Content: View>: View {
    let layout: SurfaceLayout
    let singleColumn: Bool
    let editing: Bool
    let libraryPreview: SurfaceLibraryPreview?
    let selected: String?
    let select: (String) -> Void
    let place: (SurfaceWidget, String?) -> Void
    let inspect: ((String) -> Void)?
    let measured: (String, CGRect) -> Void
    let reorder: (String, String?) -> Void
    let configure: (SurfaceTile) -> Void
    let placeAt: ((SurfaceWidget, Int, Int) -> Void)?
    let content: (SurfaceTile) -> Content
    @State private var width: CGFloat = 600
    @State private var frames: [String: CGRect] = [:]
    @State private var dropWidget: SurfaceWidget?
    @State private var dropPoint: CGPoint?
    @State private var dropIdentity: UUID?

    public init(
        layout: SurfaceLayout, singleColumn: Bool, editing: Bool = false, selected: String? = nil,
        libraryPreview: SurfaceLibraryPreview? = nil,
        select: @escaping (String) -> Void = { _ in },
        place: @escaping (SurfaceWidget, String?) -> Void = { _, _ in },
        inspect: ((String) -> Void)? = nil,
        measured: @escaping (String, CGRect) -> Void = { _, _ in },
        reorder: @escaping (String, String?) -> Void = { _, _ in },
        configure: @escaping (SurfaceTile) -> Void = { _ in },
        placeAt: ((SurfaceWidget, Int, Int) -> Void)? = nil,
        @ViewBuilder content: @escaping (SurfaceTile) -> Content
    ) {
        self.layout = layout.normalized()
        self.singleColumn = singleColumn
        self.editing = editing
        self.libraryPreview = libraryPreview
        self.selected = selected
        self.select = select
        self.place = place
        self.inspect = inspect
        self.measured = measured
        self.reorder = reorder
        self.configure = configure
        self.placeAt = placeAt
        self.content = content
    }

    public var body: some View {
        VStack(spacing: UIScale.pt(layout.gap)) {
            SurfaceGridLayout(layout: layout, singleColumn: singleColumn) {
                ForEach(layout.visible) { tile in
                    SurfaceCanvasTile(
                        tile: tile, layout: layout, canvasWidth: width, singleColumn: singleColumn,
                        editing: editing, selected: selected == tile.id,
                        select: { select(tile.id) }, inspect: { (inspect ?? select)(tile.id) },
                        measured: { frame in
                            if frames[tile.id] != frame { frames[tile.id] = frame }
                            measured(tile.id, frame)
                        },
                        reorder: { y in
                            let anchor = frames.filter { $0.key != tile.id && $0.value.midY > y }
                                .min { $0.value.minY < $1.value.minY }?.key
                            reorder(tile.id, anchor)
                        },
                        configure: configure
                    ) {
                        content(tile).environment(
                            \.surfacePresentation, SurfacePresentation(tile: tile, layout: layout))
                    }
                }
            }
            .frame(minHeight: editing ? UIScale.pt(240) : nil, alignment: .top)
            .coordinateSpace(name: "surfaceCanvas")
            .onDrop(
                of: [SurfaceDrag.type],
                delegate: SurfaceGridDrop(
                    enabled: editing && layout.tiles.count < SurfaceLayout.maximumTiles,
                    widget: $dropWidget, point: $dropPoint,
                    identity: $dropIdentity
                ) { widget, point in
                    if singleColumn {
                        let anchor = layout.visible.first {
                            (frames[$0.id]?.midY ?? .infinity) * UIScale.current > point.y
                        }?.id
                        place(widget, anchor)
                        return
                    }
                    let pitch = (width + UIScale.pt(layout.gap)) / CGFloat(layout.columns)
                    let column = max(0, min(layout.columns - 1, Int(point.x / pitch)))
                    let row = max(0, Int((point.y / UIScale.pt(layout.rowHeight)).rounded()))
                    if let placeAt { placeAt(widget, column, row) } else { place(widget, nil) }
                }
            )
            .overlay(alignment: .topLeading) {
                if editing, let widget = libraryPreview?.widget ?? dropWidget,
                    let point = libraryPreview?.point ?? dropPoint
                {
                    let frame = dropFrame(widget, at: point)
                    RoundedRectangle(cornerRadius: UIScale.pt(layout.cornerRadius))
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: UIScale.pt(layout.cornerRadius))
                                .strokeBorder(
                                    Color.accentColor,
                                    style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        }
                        .overlay(alignment: .topLeading) {
                            Label("Add " + widget.title, systemImage: "plus.circle.fill")
                                .font(.edithText(.caption)).padding(UIScale.pt(8))
                                .background(
                                    .regularMaterial,
                                    in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
                        }
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if editing, !singleColumn {
                    Canvas { context, size in
                        let pitch = max(
                            0.01, (size.width + UIScale.pt(layout.gap)) / CGFloat(layout.columns))
                        var lines = Path()
                        for column in stride(
                            from: 0, through: layout.columns, by: max(1, Int(ceil(8 / pitch))))
                        {
                            let x = CGFloat(column) * pitch
                            lines.move(to: CGPoint(x: x, y: 0))
                            lines.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        let unit = max(8, UIScale.pt(layout.rowHeight))
                        for row in 0...Int(size.height / unit) {
                            let y = CGFloat(row) * unit
                            lines.move(to: CGPoint(x: 0, y: y))
                            lines.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(lines, with: .color(.secondary.opacity(0.1)), lineWidth: 0.5)
                    }
                }
            }
            if editing {
                Label("Drop a widget to add it", systemImage: "plus.circle")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(UIScale.pt(20))
                    .background(
                        Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)
                    )
                    .onDrop(of: [SurfaceDrag.type], isTargeted: nil) {
                        SurfaceDrag.accept($0) { place($0, nil) }
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }
    private func dropFrame(_ widget: SurfaceWidget, at point: CGPoint) -> CGRect {
        if singleColumn {
            let anchor = layout.visible.first {
                (frames[$0.id]?.midY ?? .infinity) * UIScale.current > point.y
            }
            let y = anchor.flatMap { frames[$0.id]?.minY } ?? frames.values.map(\.maxY).max() ?? 0
            return CGRect(x: 0, y: y * UIScale.current, width: width, height: UIScale.pt(48))
        }
        let pitch = max(0.01, (width + UIScale.pt(layout.gap)) / CGFloat(layout.columns))
        var preview = layout
        let column = max(0, min(layout.columns - 1, Int(point.x / pitch)))
        let row = max(
            0,
            min(SurfaceLayout.maximumRow, Int((point.y / UIScale.pt(layout.rowHeight)).rounded())))
        let id = preview.add(widget, column: column, row: row)
        preview = preview.normalized()
        let tiles = preview.visible
        let heights = tiles.map { $0.id == id ? 180 : Double(frames[$0.id]?.height ?? 100) }
        let measuredTiles = tiles.map { tile in
            var measured = tile
            measured.height = nil
            return measured
        }
        let positions = SurfaceGridPacking.pack(
            tiles: measuredTiles, columns: preview.columns, heights: heights,
            rowHeight: preview.rowHeight,
            gap: preview.gap)
        guard let index = tiles.firstIndex(where: { $0.id == id }),
            positions.indices.contains(index)
        else { return .zero }
        let position = positions[index]
        return CGRect(
            x: CGFloat(position.column) * pitch,
            y: CGFloat(position.row) * UIScale.pt(layout.rowHeight),
            width: max(1, CGFloat(position.span) * pitch - UIScale.pt(layout.gap)),
            height: max(
                1, CGFloat(position.rows) * UIScale.pt(layout.rowHeight) - UIScale.pt(layout.gap)))
    }

}

private struct SurfaceGridDrop: DropDelegate {
    let enabled: Bool
    @Binding var widget: SurfaceWidget?
    @Binding var point: CGPoint?
    @Binding var identity: UUID?
    let place: @MainActor (SurfaceWidget, CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [SurfaceDrag.type])
    }
    func dropEntered(info: DropInfo) {
        guard enabled else { return }
        let token = UUID()
        identity = token
        point = info.location
        SurfaceDrag.accept(info.itemProviders(for: [SurfaceDrag.type])) { value in
            guard identity == token else { return }
            widget = value
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard enabled else { return DropProposal(operation: .forbidden) }
        point = info.location
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { clear() }
    func performDrop(info: DropInfo) -> Bool {
        guard enabled else { clear(); return false }
        let location = info.location
        clear()
        return SurfaceDrag.accept(info.itemProviders(for: [SurfaceDrag.type])) {
            place($0, location)
        }
    }
    private func clear() { widget = nil; point = nil; identity = nil }
}

public struct SurfaceGridLayout: Layout {
    let layout: SurfaceLayout
    let singleColumn: Bool

    public init(layout: SurfaceLayout, singleColumn: Bool) {
        self.layout = layout.normalized()
        self.singleColumn = singleColumn
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
        -> CGSize
    {
        let width = proposal.width ?? 600
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let frames = frames(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, frames) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let gap = UIScale.pt(layout.gap)
        if singleColumn {
            var y: CGFloat = 0
            return subviews.map { view in
                let height = view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                defer { y += height + gap }
                return CGRect(x: 0, y: y, width: width, height: height)
            }
        }
        let pitch = (width + gap) / CGFloat(layout.columns)
        let tiles = layout.visible
        let heights = zip(subviews, tiles).map { view, tile in
            Double(
                view.sizeThatFits(
                    ProposedViewSize(
                        width: max(1, CGFloat(tile.span) * pitch - gap), height: nil)
                ).height / UIScale.current)
        }
        let measuredTiles = tiles.map { tile in
            var measured = tile
            measured.height = nil
            return measured
        }
        let frames = SurfaceGridPacking.pack(
            tiles: measuredTiles, columns: layout.columns, heights: heights,
            rowHeight: layout.rowHeight, gap: layout.gap)
        return frames.map { frame in
            CGRect(
                x: CGFloat(frame.column) * pitch,
                y: CGFloat(frame.row) * UIScale.pt(layout.rowHeight),
                width: max(1, CGFloat(frame.span) * pitch - gap),
                height: max(1, CGFloat(frame.rows) * UIScale.pt(layout.rowHeight) - gap))
        }
    }
}

private struct SurfaceCanvasTile<Content: View>: View {
    let tile: SurfaceTile
    let layout: SurfaceLayout
    let canvasWidth: CGFloat
    let singleColumn: Bool
    let editing: Bool
    let selected: Bool
    let select: () -> Void
    let inspect: () -> Void
    let measured: (CGRect) -> Void
    let reorder: (Double) -> Void
    let configure: (SurfaceTile) -> Void
    @ViewBuilder let content: () -> Content
    @State private var frame = CGRect.zero
    @State private var movement = CGSize.zero
    @State private var sizing = CGSize.zero
    @State private var gestureFrame: CGRect?
    @State private var contentHeight: CGFloat = 100
    @State private var gestureContentHeight: CGFloat?

    private var pitch: CGFloat { (canvasWidth + UIScale.pt(layout.gap)) / CGFloat(layout.columns) }

    private func resizedHeight(_ delta: CGFloat) -> Double {
        let points = Double(((gestureContentHeight ?? contentHeight) + delta) / UIScale.current)
        return min(1200, max(64, (points / layout.rowHeight).rounded() * layout.rowHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            if editing {
                HStack {
                    Image(systemName: tile.locked ? "lock.fill" : "line.3.horizontal")
                    Text(tile.displayTitle).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(tile.span)/\(layout.columns)").foregroundStyle(.secondary)
                }
                .font(.edithText(.caption))
                .padding(.horizontal, UIScale.pt(10)).padding(.top, UIScale.pt(8))
                .contentShape(Rectangle())
                .onTapGesture(perform: select)
                .gesture(
                    DragGesture(minimumDistance: tile.locked ? .infinity : 3)
                        .onChanged { drag in
                            if gestureFrame == nil {
                                gestureFrame = frame
                                select()
                            }
                            let origin = gestureFrame ?? frame
                            let column = min(
                                layout.columns - tile.span,
                                max(
                                    0,
                                    Int(((origin.minX + drag.translation.width) / pitch).rounded()))
                            )
                            let row = max(
                                0,
                                Int(
                                    ((origin.minY + drag.translation.height)
                                        / UIScale.pt(layout.rowHeight)).rounded()))
                            movement = CGSize(
                                width: singleColumn ? 0 : CGFloat(column) * pitch - origin.minX,
                                height: CGFloat(row) * UIScale.pt(layout.rowHeight) - origin.minY)
                        }
                        .onEnded { drag in
                            var next = tile
                            let origin = gestureFrame ?? frame
                            next.column = min(
                                layout.columns - tile.span,
                                max(
                                    0,
                                    Int(((origin.minX + drag.translation.width) / pitch).rounded()))
                            )
                            next.row = max(
                                0,
                                Int(
                                    ((origin.minY + drag.translation.height)
                                        / UIScale.pt(layout.rowHeight)).rounded()))
                            movement = .zero
                            gestureFrame = nil
                            if singleColumn {
                                reorder(
                                    Double(
                                        (origin.midY + drag.translation.height) / UIScale.current))
                            } else {
                                configure(next)
                            }
                        }
                )
                .help("Drag to position on the grid")
            }
            Group {
                if let height = tile.height {
                    ScrollView { content().allowsHitTesting(!editing) }
                        .frame(height: UIScale.pt(height))
                } else {
                    content().allowsHitTesting(!editing)
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                contentHeight = $0
            }
            if editing {
                HStack {
                    Button("Configure", action: inspect).font(.edithText(.caption))
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.edithText(.caption)).foregroundStyle(Color.accentColor)
                        .frame(width: UIScale.pt(28), height: UIScale.pt(22))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: tile.locked ? .infinity : 3)
                                .onChanged {
                                    if gestureFrame == nil {
                                        gestureFrame = frame
                                        gestureContentHeight = contentHeight
                                        select()
                                    }
                                    let origin = gestureFrame ?? frame
                                    let column = Int((origin.minX / pitch).rounded())
                                    let span = min(
                                        layout.columns - column,
                                        max(
                                            1,
                                            Int(
                                                ((origin.width + UIScale.pt(layout.gap)
                                                    + $0.translation.width) / pitch).rounded())))
                                    sizing = CGSize(
                                        width: singleColumn
                                            ? 0
                                            : CGFloat(span) * pitch - UIScale.pt(layout.gap)
                                                - origin.width,
                                        height: UIScale.pt(resizedHeight($0.translation.height))
                                            - (gestureContentHeight ?? contentHeight))
                                }
                                .onEnded { drag in
                                    var next = tile
                                    let origin = gestureFrame ?? frame
                                    next.span = min(
                                        layout.columns - Int((origin.minX / pitch).rounded()),
                                        max(
                                            1,
                                            Int(
                                                ((origin.width + UIScale.pt(layout.gap)
                                                    + drag.translation.width) / pitch).rounded())))
                                    if singleColumn {
                                        next.span = tile.span
                                    } else {
                                        next.column =
                                            tile.column ?? Int((origin.minX / pitch).rounded())
                                        next.row =
                                            tile.row
                                            ?? Int(
                                                (origin.minY / UIScale.pt(layout.rowHeight))
                                                    .rounded())
                                    }
                                    next.height = resizedHeight(drag.translation.height)
                                    sizing = .zero
                                    gestureFrame = nil
                                    gestureContentHeight = nil
                                    configure(next)
                                }
                        )
                        .help(
                            tile.locked
                                ? "Unlock this widget to resize" : "Drag to resize width and height"
                        )
                }
                .padding(.horizontal, UIScale.pt(10)).padding(.bottom, UIScale.pt(6))
            }
        }
        .onTapGesture { if editing { select() } }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("surfaceCanvas"))
        } action: {
            frame = $0
            if movement == .zero, sizing == .zero {
                measured(
                    CGRect(
                        x: $0.minX / UIScale.current, y: $0.minY / UIScale.current,
                        width: $0.width / UIScale.current, height: $0.height / UIScale.current))
            }
        }
        .background {
            if editing {
                RoundedRectangle(cornerRadius: UIScale.pt(layout.cornerRadius))
                    .fill(Color.accentColor.opacity(selected ? 0.08 : 0.025))
            }
        }
        .overlay(alignment: .topLeading) {
            if editing {
                RoundedRectangle(cornerRadius: UIScale.pt(layout.cornerRadius))
                    .strokeBorder(
                        selected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: selected ? 2 : 1
                    )
                    .frame(
                        width: max(40, frame.width + sizing.width),
                        height: max(40, frame.height + sizing.height)
                    )
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if editing, movement != .zero || sizing != .zero {
                VStack(alignment: .trailing, spacing: UIScale.pt(3)) {
                    if movement != .zero {
                        Text(
                            "Column \(Int(((gestureFrame ?? frame).minX + movement.width) / pitch)) · \(Int(((gestureFrame ?? frame).minY + movement.height) / UIScale.current)) pt"
                        )
                    } else {
                        Text(
                            "\(Int((frame.width + sizing.width) / UIScale.current)) × \(Int(((gestureContentHeight ?? contentHeight) + sizing.height) / UIScale.current)) pt"
                        )
                    }
                }
                .font(.edithText(.caption)).monospacedDigit()
                .padding(UIScale.pt(6))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
                .offset(y: -UIScale.pt(30))
                .allowsHitTesting(false)
            }
        }
        .offset(movement)
        .zIndex(movement == .zero && sizing == .zero ? 0 : 1)
    }
}

public enum SurfaceTabDrag {
    public static let type = UTType(exportedAs: "app.edith.notch-tab", conformingTo: .data)
    public static func provider(_ raw: String) -> NSItemProvider {
        NSItemProvider(item: Data(raw.utf8) as NSData, typeIdentifier: type.identifier)
    }
    public static func accept(
        _ providers: [NSItemProvider], perform: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(type.identifier)
            })
        else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, data.count < 128, let token = String(data: data, encoding: .utf8),
                let tab = SurfaceNotchTab(rawValue: token)
            else { return }
            Task { @MainActor in perform(tab.rawValue) }
        }
        return true
    }
}
