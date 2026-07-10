import AppKit
import EdithKit
import SwiftUI

struct NotchShelfContentView: View {
    @ObservedObject var controller: NotchShelfController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(.black)
            if controller.isExpanded {
                expanded.transition(.opacity)
            } else {
                collapsed.transition(.opacity)
            }
        }
        .animation(shapeAnimation, value: controller.isExpanded)
        .animation(.easeOut(duration: 0.14), value: controller.isResizing)
        .onHover { controller.hoverChanged($0) }
    }

    private var topRadius: CGFloat {
        controller.isExpanded ? NotchGeometry.expandedTopRadius : NotchGeometry.topFlareRadius
    }

    private var bottomRadius: CGFloat {
        guard controller.isExpanded else { return 14 }
        return controller.isResizing
            ? NotchGeometry.resizingBottomRadius : NotchGeometry.expandedBottomRadius
    }

    private var shapeAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.22) : .spring(response: 0.36, dampingFraction: 0.9)
    }

    @ViewBuilder private var collapsed: some View {
        if let track = controller.nowPlaying {
            NotchMusicWings(controller: controller, track: track)
        } else if !controller.items.isEmpty {
            Text("\(controller.items.count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
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
                ResizeEdges(controller: controller, hInset: NotchGeometry.expandedTopRadius)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .coordinateSpace(name: "shelfCanvas")
        }
    }
}

private struct NotchMusicWings: View {
    @ObservedObject var controller: NotchShelfController
    let track: NotchNowPlaying

    var body: some View {
        HStack(spacing: 0) {
            artwork
                .frame(width: NotchGeometry.musicWingWidth)
            Spacer(minLength: 0)
            PlaybackWave(playing: track.isPlaying, color: .white.opacity(0.85), barCount: 4)
                .frame(width: NotchGeometry.musicWingWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var artwork: some View {
        if let image = controller.nowPlayingArtwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct ResizeEdges: View {
    let controller: NotchShelfController
    let hInset: CGFloat

    var body: some View {
        Color.clear
            .overlay(alignment: .leading) {
                strip(cursor: .resizeLeftRight, resizesWidth: true, resizesHeight: false)
                    .frame(width: 10)
                    .padding(.leading, hInset)
            }
            .overlay(alignment: .trailing) {
                strip(cursor: .resizeLeftRight, resizesWidth: true, resizesHeight: false)
                    .frame(width: 10)
                    .padding(.trailing, hInset)
            }
            .overlay(alignment: .bottom) {
                strip(cursor: .resizeUpDown, resizesWidth: false, resizesHeight: true)
                    .frame(height: 10)
                    .padding(.horizontal, hInset)
            }
            .overlay(alignment: .bottomLeading) {
                strip(
                    cursor: Self.diagonalCursor(rightSide: false), resizesWidth: true,
                    resizesHeight: true
                )
                .frame(width: 20, height: 20)
                .padding(.leading, hInset)
            }
            .overlay(alignment: .bottomTrailing) {
                strip(
                    cursor: Self.diagonalCursor(rightSide: true), resizesWidth: true,
                    resizesHeight: true
                )
                .frame(width: 20, height: 20)
                .padding(.trailing, hInset)
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
                    .onEnded { _ in controller.endResize() }
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
