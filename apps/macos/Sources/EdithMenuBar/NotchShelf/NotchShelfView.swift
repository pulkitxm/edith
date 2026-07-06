import AppKit
import SwiftUI

struct NotchShelfContentView: View {
    @ObservedObject var controller: NotchShelfController

    var body: some View {
        ZStack {
            if controller.isExpanded {
                expanded
            } else {
                collapsed
            }
        }
        .onHover { controller.hoverChanged($0) }
    }

    private var collapsed: some View {
        NotchShape()
            .fill(.black)
            .overlay {
                if !controller.items.isEmpty {
                    Text("\(controller.items.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
    }

    private var expanded: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if controller.items.isEmpty {
                    Text("Drop files here to park them")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ForEach(Array(controller.items.enumerated()), id: \.element.id) {
                        index, item in
                        ShelfItemView(item: item, controller: controller, canvasSize: geo.size)
                            .position(
                                NotchGeometry.itemPosition(
                                    stored: controller.livePositions[item.id] ?? item.position,
                                    index: index, in: geo.size))
                    }
                }
                if controller.isOptionHeld {
                    ResizeEdges(controller: controller)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .coordinateSpace(name: "shelfCanvas")
        }
        .onContinuousHover { _ in controller.refreshOptionState() }
        .background(.black, in: NotchShape(bottomRadius: 22))
    }
}

private struct ResizeEdges: View {
    let controller: NotchShelfController

    var body: some View {
        Color.clear
            .overlay(alignment: .leading) {
                strip(cursor: .resizeLeftRight, resizesWidth: true, resizesHeight: false)
                    .frame(width: 8)
            }
            .overlay(alignment: .trailing) {
                strip(cursor: .resizeLeftRight, resizesWidth: true, resizesHeight: false)
                    .frame(width: 8)
            }
            .overlay(alignment: .bottom) {
                strip(cursor: .resizeUpDown, resizesWidth: false, resizesHeight: true)
                    .frame(height: 8)
            }
            .overlay(alignment: .bottomLeading) {
                strip(
                    cursor: Self.diagonalCursor(rightSide: false), resizesWidth: true,
                    resizesHeight: true
                )
                .frame(width: 16, height: 16)
            }
            .overlay(alignment: .bottomTrailing) {
                strip(
                    cursor: Self.diagonalCursor(rightSide: true), resizesWidth: true,
                    resizesHeight: true
                )
                .frame(width: 16, height: 16)
            }
            .onDisappear { NSCursor.arrow.set() }
    }

    private func strip(cursor: NSCursor, resizesWidth: Bool, resizesHeight: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: cursor.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in
                        cursor.set()
                        controller.resizeExpanded(
                            toPointer: NSEvent.mouseLocation,
                            resizesWidth: resizesWidth, resizesHeight: resizesHeight)
                    }
            )
    }

    private static func diagonalCursor(rightSide: Bool) -> NSCursor {
        if #available(macOS 15, *) {
            return .frameResize(position: rightSide ? .bottomRight : .bottomLeft, directions: .all)
        }
        return .crosshair
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    @ObservedObject var controller: NotchShelfController
    let canvasSize: CGSize
    @State private var handedOffToSystemDrag = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Image(
                nsImage: thumbnail
                    ?? NSWorkspace.shared.icon(forFile: controller.fileURL(for: item).path)
            )
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 64)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(controller.selectedIDs.contains(item.id) ? 0.2 : 0))
        )
        .contentShape(Rectangle())
        .gesture(moveOrDragOut)
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                controller.toggleSelection(item)
            } else {
                controller.open(item)
            }
        }
        .contextMenu {
            Button("Open") { controller.open(item) }
            Button("Reveal in Finder") { controller.reveal(item) }
            Button("Share") { controller.share(item) }
            Button("Delete", role: .destructive) { controller.remove(item) }
        }
        .task(id: item.name) {
            thumbnail = await ShelfThumbnails.thumbnail(for: controller.fileURL(for: item))
        }
    }

    private var moveOrDragOut: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("shelfCanvas"))
            .onChanged { value in
                guard !handedOffToSystemDrag else { return }
                if CGRect(origin: .zero, size: canvasSize).contains(value.location) {
                    controller.canvasDrag(item, to: value.location, in: canvasSize)
                } else {
                    handedOffToSystemDrag = true
                    controller.beginExternalDrag(of: item)
                }
            }
            .onEnded { _ in
                handedOffToSystemDrag = false
                controller.endCanvasDrag()
            }
    }
}
