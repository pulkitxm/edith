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
                        ShelfItemView(item: item, controller: controller)
                            .position(
                                NotchGeometry.itemPosition(
                                    stored: item.position, index: index, in: geo.size))
                    }
                }
                if controller.isOptionHeld {
                    ResizeEdges(controller: controller)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
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
            .onHover { inside in (inside ? cursor : NSCursor.arrow).set() }
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

    var body: some View {
        Menu {
            Button("Open") { controller.open(item) }
            Button("Reveal in Finder") { controller.reveal(item) }
            Button("Clear", role: .destructive) { controller.remove(item) }
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: controller.fileURL(for: item).path))
                    .resizable()
                    .frame(width: 38, height: 38)
                Text(item.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 64)
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .onDrag { controller.dragOutProvider(for: item) }
    }
}
