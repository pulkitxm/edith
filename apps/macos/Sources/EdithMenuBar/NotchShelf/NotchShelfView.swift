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
            } else if let alert = controller.currentAlert {
                NotchAlertDropView(alert: alert, controller: controller).transition(.opacity)
            } else {
                collapsed.transition(.opacity)
            }
        }
        .animation(shapeAnimation, value: controller.isExpanded)
        .animation(shapeAnimation, value: controller.currentAlert)
        .animation(.easeOut(duration: 0.14), value: controller.isResizing)
        .onHover { controller.hoverChanged($0) }
    }

    private var topRadius: CGFloat {
        controller.isExpanded || controller.currentAlert != nil
            ? NotchGeometry.expandedTopRadius : NotchGeometry.topFlareRadius
    }

    private var bottomRadius: CGFloat {
        if controller.currentAlert != nil, !controller.isExpanded { return 22 }
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
        ZStack {
            VStack(spacing: 4) {
                tabStrip
                    .padding(.top, 30)
                    .padding(.horizontal, 16)
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            GeometryReader { geo in
                ResizeEdges(controller: controller, hInset: NotchGeometry.expandedTopRadius)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(NotchTab.allCases, id: \.self) { tab in
                Button {
                    controller.selectTab(tab)
                } label: {
                    Text(tab.title)
                        .font(
                            .system(
                                size: 11.5,
                                weight: controller.activeTab == tab ? .semibold : .regular)
                        )
                        .foregroundStyle(
                            controller.activeTab == tab ? Color.black : Color.white.opacity(0.7)
                        )
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(
                            controller.activeTab == tab
                                ? Color.white.opacity(0.92) : Color.white.opacity(0.07),
                            in: Capsule())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            Spacer()
            Button {
                MainApp.openDashboard()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain).pointerCursor()
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch controller.activeTab {
        case .home: NotchHomeTab(controller: controller)
        case .files: filesCanvas
        case .clipboard: NotchClipboardTab(controller: controller)
        case .camera: NotchCameraTab()
        }
    }

    private var filesCanvas: some View {
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
            }
            .coordinateSpace(name: "shelfCanvas")
        }
    }
}

private struct NotchHomeTab: View {
    @ObservedObject var controller: NotchShelfController

    var body: some View {
        VStack(spacing: 6) {
            if let track = controller.nowPlaying {
                nowPlaying(track)
            }
            if let usage = controller.usageStore {
                NotchUsageRings(usage: usage)
            }
            if controller.nowPlaying == nil, controller.usageStore == nil {
                Text("Nothing to show yet")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func nowPlaying(_ track: NotchNowPlaying) -> some View {
        HStack(spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                HStack(spacing: 24) {
                    control("backward.fill", size: 14) { controller.nowPlayingPrevious() }
                    control(track.isPlaying ? "pause.fill" : "play.fill", size: 19) {
                        controller.nowPlayingPlayPause()
                    }
                    control("forward.fill", size: 14) { controller.nowPlayingNext() }
                }
                .padding(.top, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
    }

    private var artwork: some View {
        Group {
            if let image = controller.nowPlayingArtwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.08))
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func control(_ name: String, size: CGFloat, _ action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size)).foregroundStyle(.white)
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

private struct NotchUsageRings: View {
    @ObservedObject var usage: UsageStore

    var body: some View {
        HStack(spacing: 26) {
            ring("Session", usage.session?.percent)
            ring("Week", usage.week?.percent)
        }
        .padding(.bottom, 12)
    }

    private func ring(_ label: String, _ percent: Double?) -> some View {
        let value = percent ?? 0
        return VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(1, value / 100))
                    .stroke(color(value), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value.rounded()))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func color(_ percent: Double) -> Color {
        if percent >= 85 { return Color(red: 0.88, green: 0.4, blue: 0.31) }
        if percent >= 60 { return Color(red: 0.88, green: 0.66, blue: 0.25) }
        return Color(red: 0.3, green: 0.77, blue: 0.49)
    }
}

private struct NotchClipboardTab: View {
    @ObservedObject var controller: NotchShelfController

    var body: some View {
        if let store = controller.clipboardStore {
            NotchClipboardList(store: store, controller: controller)
        } else {
            Text("Clipboard history is off")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NotchClipboardList: View {
    @ObservedObject var store: ClipboardStore
    let controller: NotchShelfController

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(store.entries.prefix(8)) { entry in
                    Button {
                        controller.copyClipboardEntry(entry)
                    } label: {
                        HStack(spacing: 8) {
                            Text(entry.preview ?? "Non-text item")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if entry.pinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }
}

private struct NotchAlertDropView: View {
    let alert: NotchAlert
    @ObservedObject var controller: NotchShelfController

    var body: some View {
        let tint = Color(hex: alert.tint)
        return HStack(spacing: 12) {
            Image(systemName: alert.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1)
                if let subtitle = alert.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .contentShape(Rectangle())
        .onHover { controller.alertHover($0) }
        .onTapGesture { controller.dismissAlert() }
    }
}

extension Color {
    fileprivate init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
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
