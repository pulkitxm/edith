import AVFoundation
import CoreGraphics
import Foundation

enum VideoSelection: Equatable {
    case clip(String), zoom(String), annotation(String), audio(String), speed(String), camera(
        String)
    case webcam
}

extension VideoProject {
    mutating func editRegion(_ key: String, id: String, change: (inout [String: Any]) -> Void) {
        let nested = ["speedRegions", "cameraFullscreenRegions"].contains(key)
        var container = nested ? root["legacyEditor"] as? [String: Any] ?? [:] : root
        var entries = container[key] as? [[String: Any]] ?? []
        guard let index = entries.firstIndex(where: { $0["id"] as? String == id }) else { return }
        change(&entries[index])
        container[key] = entries
        if nested { root["legacyEditor"] = container } else { root = container }
    }

    mutating func retimeRegion(
        _ key: String, id: String, start: Double, end: Double, trimStart: Bool
    ) {
        if key == "annotations", annotations.first(where: { $0.id == id })?.outputCaption != nil {
            try? retimeOutputCaption(id, start: start, end: end)
            return
        }
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 0.05 else { return }
        if key == "audioTracks" {
            retimeAudio(id, start: start, end: end, trimStart: trimStart)
            return
        }
        let anchor = clips.first {
            start >= $0.timelineStart && end <= $0.timelineStart + $0.duration
        }
        editRegion(key, id: id) { region in
            region["startMs"] = start * 1000
            region["endMs"] = end * 1000
            region["clipId"] = anchor?.id
            region["sourceStartSec"] = anchor.map { $0.start + start - $0.timelineStart }
            region["sourceEndSec"] = anchor.map { $0.start + end - $0.timelineStart }
        }
    }
}

extension VideoEditorModel {
    var rulerPlayhead: Double { rulerTime(at: playhead) }

    func rulerTime(at output: Double) -> Double {
        guard let segments = pipeline?.segments, let last = segments.last else { return output }
        let segment = segments.first { output < $0.outputEnd } ?? last
        return segment.rulerTime(at: min(segment.outputEnd, max(segment.outputStart, output)))
    }

    func select(_ item: VideoSelection) {
        player.pause()
        selection = item
        editingZoomID = nil
        switch item {
        case .zoom(let id):
            if let zoom = project?.zooms.first(where: { $0.id == id }) { selectZoom(zoom) }
        case .clip(let id):
            selectedClipID = id
            if let segment = pipeline?.segments.first(where: { $0.clip.id == id }) {
                seek(to: segment.outputStart)
            }
        case .annotation(let id):
            if let region = project?.annotations.first(where: { $0.id == id }) {
                seek(to: captionOutputRange(region).start)
            }
        default: break
        }
    }

    func deleteSelection() {
        switch selection {
        case .clip(let id): selectedClipID = id; removeSelected()
        case .zoom(let id): removeZoom(id)
        case .annotation(let id): removeCaption(id)
        case .audio(let id): removeAudio(id)
        case .speed(let id): removeSpeed(id)
        case .camera(let id): removeFullCamera(id)
        case .webcam: removeCameraFromSelectedClip()
        case nil: return
        }
        selection = nil
    }

    func retime(_ key: String, id: String, range: ZoomTimelineTiming.Range, edge: String) {
        if key == "annotations",
            project?.annotations.first(where: { $0.id == id })?.outputCaption != nil
        {
            do {
                guard var candidate = project else { return }
                try candidate.retimeOutputCaption(id, start: range.start, end: range.end)
                mutate { $0 = candidate }
                rebuild()
            } catch { errorMessage = error.localizedDescription }
            return
        }
        mutate {
            $0.retimeRegion(
                key, id: id, start: key == "audioTracks" ? range.start : rulerTime(at: range.start),
                end: key == "audioTracks" ? range.end : rulerTime(at: range.end),
                trimStart: edge == "start")
        }
        rebuild()
    }

    func editClip(_ id: String, range: ZoomTimelineTiming.Range, edge: String) {
        guard let clip = project?.clips.first(where: { $0.id == id }),
            let segments = pipeline?.segments.filter({ $0.clip.id == id }),
            let first = segments.first, let last = segments.last
        else { return }
        if edge == "move" {
            let destination = range.start + (range.end - range.start) / 2
            let target = pipeline?.segments.first { destination < $0.outputEnd }?.clip.id
            mutate { document in
                var clips = document.clips
                guard let from = clips.firstIndex(where: { $0.id == id }),
                    let to = clips.firstIndex(where: { $0.id == target }), from != to
                else { return }
                let moved = clips.remove(at: from)
                clips.insert(moved, at: to)
                document.setClips(clips)
            }
        } else {
            let start =
                edge == "start"
                ? max(0, clip.start + (range.start - first.outputStart) * first.rate) : clip.start
            let end =
                edge == "end"
                ? min(
                    project?.assets.first { $0.id == clip.assetID }?.duration ?? clip.end,
                    clip.end + (range.end - last.outputEnd) * last.rate) : clip.end
            mutate { $0.trim(clipID: id, start: start, end: end) }
        }
        selectedClipID = id
        rebuild()
    }

    func placeAnnotation(_ id: String, rect: CGRect) {
        mutate {
            $0.editRegion("annotations", id: id) { region in
                let original = region["size"] as? [String: Double] ?? [:]
                if region["type"] as? String == "text" {
                    var style = region["style"] as? [String: Any] ?? [:]
                    let size = (style["fontSize"] as? NSNumber)?.doubleValue ?? 32
                    style["fontSize"] = min(
                        192, max(8, size * rect.width / max(0.01, (original["width"] ?? 60) / 100)))
                    region["style"] = style
                }
                region["position"] = ["x": rect.midX * 100, "y": rect.midY * 100]
                region["size"] = ["width": rect.width * 100, "height": rect.height * 100]
            }
        }
        rebuild()
    }

    func placeCamera(_ rect: CGRect) {
        mutate {
            $0.webcamPosition = ["cx": rect.midX, "cy": rect.midY]
            $0.webcamSize = rect.width * 100
        }
        rebuild()
    }
}

enum VideoCanvasGeometry {
    static func rect(position: [String: Double], size: [String: Double]) -> CGRect {
        let width = (size["width"] ?? 60) / 100
        let height = (size["height"] ?? 12) / 100
        return CGRect(
            x: (position["x"] ?? 50) / 100 - width / 2,
            y: (position["y"] ?? 80) / 100 - height / 2, width: width, height: height)
    }

    static func adjust(_ original: CGRect, translation: CGSize, handle: String, snap: Bool = true)
        -> CGRect
    {
        var rect = original
        if handle == "move" {
            rect.origin.x += translation.width
            rect.origin.y += translation.height
            if snap {
                if abs(rect.midX - 0.5) < 0.012 { rect.origin.x = 0.5 - rect.width / 2 }
                if abs(rect.midY - 0.5) < 0.012 { rect.origin.y = 0.5 - rect.height / 2 }
            }
        } else {
            rect.size.width = min(1, max(0.03, rect.width + translation.width))
            rect.size.height = min(1, max(0.03, rect.height + translation.height))
        }
        rect.origin.x = min(1 - rect.width, max(0, rect.minX))
        rect.origin.y = min(1 - rect.height, max(0, rect.minY))
        return rect
    }
}
