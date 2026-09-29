import SwiftUI

struct VideoTimeline: View {
    let model: VideoEditorModel
    @State private var scale = 80.0
    @State private var snapping = true

    private struct Item: Identifiable {
        let id: String
        let label: String
        let start: Double
        let end: Double
        let selection: VideoSelection
        let key: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Timeline", systemImage: "rectangle.stack").font(.headline)
                Button("Split", systemImage: "scissors", action: model.splitAtPlayhead)
                Button("Delete", systemImage: "trash", action: model.deleteSelection)
                    .disabled(model.selection == nil)
                Toggle("Snap", isOn: $snapping).toggleStyle(.button)
                Spacer()
                Text("Drag to move · edges to trim").font(.caption).foregroundStyle(.secondary)
                Button("Fit") { scale = max(8, min(180, 900 / max(1, model.duration))) }
                Slider(value: $scale, in: 8...240).frame(width: 110).accessibilityLabel(
                    "Timeline scale")
            }
            .buttonStyle(.borderless).padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                let width = max(900, model.duration * scale + 80)
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        ruler(width: width)
                        lane("VIDEO", color: .blue, items: clipItems, width: width)
                        zoomLane(width: width)
                        ForEach(packed(annotationItems), id: \.first?.id) { items in
                            lane("OVERLAYS", color: .orange, items: items, width: width)
                        }
                        ForEach(audioLanes, id: \.first?.id) { items in
                            lane("AUDIO", color: .green, items: items, width: width)
                        }
                        lane("SPEED", color: .purple, items: regions("speedRegions"), width: width)
                        lane(
                            "CAMERA", color: .pink, items: regions("cameraFullscreenRegions"),
                            width: width)
                    }
                    Rectangle().fill(.red).frame(width: 1.5)
                        .offset(x: 90 + model.playhead * scale).allowsHitTesting(false)
                }
                .frame(width: width + 90).padding(.vertical, 8)
            }
            .coordinateSpace(name: "editTimeline")
        }
        .frame(minHeight: 180, idealHeight: 240, maxHeight: 280)
    }

    private func ruler(width: Double) -> some View {
        let step = max(1, Int(ceil(60 / scale)))
        return HStack(spacing: 0) {
            Text("TIME").font(.caption2).foregroundStyle(.secondary).frame(width: 90)
            Canvas { context, size in
                for second in stride(from: 0, through: Int(ceil(model.duration)), by: step) {
                    context.draw(
                        Text(time(Double(second))).font(.caption2).foregroundStyle(.secondary),
                        at: CGPoint(x: Double(second) * scale + 2, y: 10), anchor: .leading)
                }
            }
            .frame(width: width, height: 26).contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { model.seek(to: $0.location.x / scale) }
            )
            .accessibilityLabel("Scrub timeline")
        }
    }

    private func lane(_ title: String, color: Color, items: [Item], width: Double) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 90)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.06))
                ForEach(items) { item in
                    VideoTimelineRegion(
                        title: item.label, start: item.start, end: item.end,
                        scale: scale, duration: model.duration, color: color,
                        selected: model.selection == item.selection,
                        snaps: snapping ? snapPoints : [], select: { model.select(item.selection) }
                    ) { range, edge in
                        if item.key == "clips" {
                            model.editClip(item.id, range: range, edge: edge)
                        } else {
                            model.retime(item.key, id: item.id, range: range, edge: edge)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        waveform(item).frame(height: 10).padding(.horizontal, 12).padding(
                            .bottom, 2)
                    }
                    .offset(x: item.start * scale)
                }
            }.frame(width: width, height: 38)
        }
    }

    private func zoomLane(width: Double) -> some View {
        HStack(spacing: 0) {
            Text("ZOOM").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 90)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.06))
                ForEach(model.project?.zooms ?? []) { zoom in
                    let start = model.outputTime(forRulerTime: zoom.startMs / 1000)
                    let end = model.outputTime(forRulerTime: zoom.endMs / 1000)
                    let others = (model.project?.zooms ?? []).filter { $0.id != zoom.id }
                    let lower =
                        others.map { model.outputTime(forRulerTime: $0.endMs / 1000) }.filter {
                            $0 <= start
                        }.max() ?? 0
                    let upper =
                        others.map { model.outputTime(forRulerTime: $0.startMs / 1000) }.filter {
                            $0 >= end
                        }.min() ?? model.duration
                    ZoomTimelineRegion(
                        zoom: zoom, start: start, end: end, lowerBound: lower,
                        upperBound: upper, pointsPerSecond: scale,
                        selected: model.editingZoomID == zoom.id,
                        select: { model.select(.zoom(zoom.id)) },
                        adjust: { model.setZoomTiming(zoom.id, start: $0.start, end: $0.end) }
                    )
                    .offset(x: start * scale)
                }
            }.frame(width: width, height: 38).coordinateSpace(name: "zoomTimeline")
        }
    }

    @ViewBuilder private func waveform(_ item: Item) -> some View {
        if item.key == "clips", let clip = model.project?.clips.first(where: { $0.id == item.id }),
            let asset = model.project?.assets.first(where: { $0.id == clip.assetID })
        {
            HStack(spacing: 0) {
                ForEach(
                    Array(
                        (model.pipeline?.segments.filter { $0.clip.id == clip.id } ?? [])
                            .enumerated()), id: \.offset
                ) { _, segment in
                    VideoWaveform(
                        url: asset.audioURL, start: segment.sourceStart, end: segment.sourceEnd
                    )
                    .frame(width: max(1, segment.outputDuration * scale - 2))
                }
            }.clipped().allowsHitTesting(false)
        } else if item.key == "audioTracks",
            let track = model.project?.audioTracks.first(where: { $0.id == item.id }),
            let asset = model.project?.assets.first(where: { $0.id == track.assetID })
        {
            VideoWaveform(
                url: asset.audioURL, start: track.offsetMs / 1000,
                end: track.offsetMs / 1000 + (track.endMs - track.startMs) * track.rate / 1000,
                loop: track.loop)
        }
    }

    private var clipItems: [Item] {
        (model.project?.clips ?? []).compactMap { clip in
            let segments = model.pipeline?.segments.filter { $0.clip.id == clip.id } ?? []
            guard let start = segments.first?.outputStart, let end = segments.last?.outputEnd else {
                return nil
            }
            let label = model.project?.assets.first { $0.id == clip.assetID }?.label ?? "Video"
            return Item(
                id: clip.id, label: label, start: start, end: end, selection: .clip(clip.id),
                key: "clips")
        }
    }

    private var annotationItems: [Item] {
        (model.project?.annotations ?? []).map {
            Item(
                id: $0.id, label: $0.type == "text" ? $0.text : $0.type.capitalized,
                start: model.captionOutputRange($0).start,
                end: model.captionOutputRange($0).end,
                selection: .annotation($0.id), key: "annotations")
        }
    }

    private var audioItems: [Item] {
        (model.project?.audioTracks ?? []).map {
            Item(
                id: $0.id, label: $0.label,
                start: $0.startMs / 1000,
                end: $0.endMs / 1000, selection: .audio($0.id),
                key: "audioTracks")
        }
    }

    private var audioLanes: [[Item]] {
        let lanes = Dictionary(
            uniqueKeysWithValues: (model.project?.audioTracks ?? []).map {
                ($0.id, $0.raw["laneId"] as? String ?? $0.id)
            })
        let grouped = Dictionary(grouping: audioItems) { lanes[$0.id] ?? $0.id }
        return grouped.values.sorted { ($0.first?.id ?? "") < ($1.first?.id ?? "") }
            .flatMap { packed($0) }
    }

    private func regions(_ key: String) -> [Item] {
        let entries =
            key == "speedRegions"
            ? model.project?.speedRegions : model.project?.cameraFullscreenRegions
        return (entries ?? []).compactMap { region in
            guard let id = region["id"] as? String else { return nil }
            let speed = (region["speed"] as? NSNumber)?.doubleValue ?? 1
            return Item(
                id: id,
                label: key == "speedRegions" ? "\(speed.formatted())×" : "Fullscreen webcam",
                start: model.outputTime(
                    forRulerTime: ((region["startMs"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                end: model.outputTime(
                    forRulerTime: ((region["endMs"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                selection: key == "speedRegions" ? .speed(id) : .camera(id), key: key)
        }
    }

    private var snapPoints: [Double] {
        [0, model.playhead, model.duration]
            + (clipItems + annotationItems + audioItems).flatMap { [$0.start, $0.end] }
    }

    private func packed(_ items: [Item]) -> [[Item]] {
        var lanes: [[Item]] = [[]]
        for item in items.sorted(by: { $0.start < $1.start }) {
            if let index = lanes.firstIndex(where: { ($0.last?.end ?? 0) <= item.start }) {
                lanes[index].append(item)
            } else {
                lanes.append([item])
            }
        }
        return lanes
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct VideoTimelineRegion: View {
    let title: String
    let start: Double
    let end: Double
    let scale: Double
    let duration: Double
    let color: Color
    let selected: Bool
    let snaps: [Double]
    let select: () -> Void
    let commit: (ZoomTimelineTiming.Range, String) -> Void
    @State private var preview: ZoomTimelineTiming.Range?

    var body: some View {
        let range = preview ?? .init(start: start, end: end)
        HStack(spacing: 0) {
            handle("start")
            Button(action: select) {
                Text(title).font(.caption).lineLimit(1).frame(
                    maxWidth: .infinity, maxHeight: .infinity
                )
                .contentShape(Rectangle())
            }.buttonStyle(.borderless).highPriorityGesture(drag("move"))
            handle("end")
        }
        .frame(width: max(28, (range.end - range.start) * scale), height: 32)
        .background(color.opacity(selected ? 0.65 : 0.3), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? .white : .clear, lineWidth: 1)
        }
        .offset(x: (range.start - start) * scale)
        .accessibilityLabel(title)
    }

    private func handle(_ edge: String) -> some View {
        Capsule().fill(.white.opacity(0.7)).frame(width: 3, height: 16)
            .frame(width: 10, height: 32).contentShape(Rectangle()).gesture(drag(edge))
            .accessibilityLabel("Trim \(title) \(edge)")
    }

    private func drag(_ edge: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("editTimeline"))
            .onChanged { preview = adjusted($0.translation.width / scale, edge: edge) }
            .onEnded { value in
                select()
                commit(adjusted(value.translation.width / scale, edge: edge), edge)
                preview = nil
            }
    }

    private func adjusted(_ delta: Double, edge: String) -> ZoomTimelineTiming.Range {
        let range = ZoomTimelineTiming.adjust(
            .init(start: start, end: end), by: delta, edge: edge,
            lower: 0, upper: max(end, duration), snapDistance: 0)
        let moving = edge == "end" ? range.end : range.start
        guard
            let target = snaps.filter({ abs($0 - start) > 0.001 && abs($0 - end) > 0.001 })
                .min(by: { abs($0 - moving) < abs($1 - moving) }), abs(target - moving) < 8 / scale
        else { return range }
        return ZoomTimelineTiming.adjust(
            range, by: target - moving, edge: edge,
            lower: 0, upper: max(end, duration), snapDistance: 0)
    }
}
