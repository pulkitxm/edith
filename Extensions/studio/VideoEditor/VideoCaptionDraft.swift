import Foundation
import Observation

@MainActor @Observable final class VideoCaptionDraft {
    let id: String
    var values: [String: String] { didSet { sync() } }
    var failure: String?
    private var saved: [String: String]
    private weak var model: VideoEditorModel?

    init(_ caption: VideoProject.Annotation, model: VideoEditorModel) {
        id = caption.id
        self.model = model
        let initial = Self.fields(caption, model: model)
        saved = initial
        values = initial
    }

    private static func fields(_ caption: VideoProject.Annotation, model: VideoEditorModel)
        -> [String: String]
    {
        let style = caption.captionStyle ?? VideoCaptionStyle()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let range = model.captionOutputRange(caption)
        var fields = [
            "text": caption.text, "start": String(range.start), "end": String(range.end),
            "fontFamily": style.fontFamily, "fontStyle": style.fontStyle,
            "alignment": style.alignment.rawValue, "anchor": style.anchor.rawValue,
            "metrics": (style.metrics ?? .typographic).rawValue,
            "json": (try? encoder.encode(style)).map { String(decoding: $0, as: UTF8.self) } ?? "",
        ]
        for (key, value) in [
            "canvasWidth": style.canvasWidth, "canvasHeight": style.canvasHeight,
            "fontSize": style.fontSize, "lineAdvance": style.lineAdvance, "x": style.x,
            "y": style.y, "width": style.width,
        ] { fields[key] = String(value) }
        return fields
    }

    func refresh(discard: Bool = false) {
        guard let model, let caption = model.project?.annotations.first(where: { $0.id == id })
        else { return }
        guard discard || !model.hasUnsavedEdits else { return }
        let next = Self.fields(caption, model: model)
        for key in next.keys where discard || matchesSaved(key) {
            values[key] = next[key]
        }
        saved = next
        if discard { failure = nil }
        sync()
    }

    private func sync() {
        for (group, keys) in [
            "text": ["text"], "time": ["start", "end"],
            "style": saved.keys.filter { !["text", "start", "end"].contains($0) },
        ] {
            model?.setPendingViewEdit(
                "caption.\(id).\(group)", hasChanges: keys.contains { !matchesSaved($0) })
        }
    }

    private func matchesSaved(_ key: String) -> Bool {
        if Self.numbers[key] != nil || ["start", "end"].contains(key),
            let value = Double(values[key] ?? ""), let original = Double(saved[key] ?? "")
        {
            return value == original
        }
        if key == "json", let value = try? VideoCaptionStyle.decode(Data((values[key] ?? "").utf8)),
            let original = try? VideoCaptionStyle.decode(Data((saved[key] ?? "").utf8))
        {
            return value == original
        }
        return values[key] == saved[key]
    }

    func apply(_ group: String) {
        guard let model, let caption = model.project?.annotations.first(where: { $0.id == id })
        else { return }
        do {
            var keys: [String]
            var candidate = model.project!
            if group == "text" {
                let text = values["text"] ?? ""
                if let style = caption.captionStyle {
                    _ = try VideoStyledCaptionImage.layout(text, style: style)
                }
                candidate.editRegion("annotations", id: id) {
                    $0["content"] = text; $0["textContent"] = text
                }
                keys = ["text"]
            } else if group == "time" {
                guard let start = Double(values["start"] ?? ""),
                    let end = Double(values["end"] ?? ""),
                    start.isFinite, end.isFinite, start >= 0, end > start, end <= model.duration
                else {
                    throw VideoEditorService.Failure(
                        "invalid_caption_time",
                        "Enter a start and end within the video, with end after start.")
                }
                if caption.outputCaption != nil {
                    try candidate.retimeOutputCaption(id, start: start, end: end)
                } else {
                    let rulerStart = model.rulerTime(at: start)
                    let rulerEnd = model.rulerTime(at: end)
                    guard rulerEnd - rulerStart >= 0.05 else {
                        throw VideoEditorService.Failure(
                            "invalid_caption_time",
                            "Caption timing must span at least 50 ruler milliseconds.")
                    }
                    candidate.retimeRegion(
                        "annotations", id: id, start: rulerStart,
                        end: rulerEnd, trimStart: false)
                }
                keys = ["start", "end"]
            } else {
                var style: VideoCaptionStyle
                if group == "json" {
                    style = try VideoCaptionStyle.decode(Data((values["json"] ?? "").utf8))
                } else {
                    style = caption.captionStyle ?? VideoCaptionStyle()
                    style.fontFamily = values["fontFamily"] ?? ""
                    style.fontStyle = values["fontStyle"] ?? ""
                    style.alignment = .init(rawValue: values["alignment"] ?? "") ?? .center
                    style.anchor = .init(rawValue: values["anchor"] ?? "") ?? .top
                    style.metrics = .init(rawValue: values["metrics"] ?? "")
                    for (key, path) in Self.numbers {
                        guard let value = Double(values[key] ?? ""), value.isFinite else {
                            throw VideoEditorService.Failure(
                                "invalid_caption_style", "Enter a finite number for \(key).")
                        }
                        style[keyPath: path] = value
                    }
                }
                _ = try VideoStyledCaptionImage.layout(caption.text, style: style)
                try candidate.setCaptionStyle(id, style: style)
                keys =
                    group == "json"
                    ? ["json"]
                    : saved.keys.filter { !["text", "start", "end", "json"].contains($0) }
            }
            model.mutate { $0 = candidate }
            guard !model.hasUnsavedEdits else {
                failure = model.errorMessage ?? "Save the project to apply this draft."; return
            }
            let next = Self.fields(model.project!.annotations.first { $0.id == id }!, model: model)
            for key in keys { values[key] = next[key]; saved[key] = next[key] }
            failure = nil
            refresh()
            model.rebuild()
        } catch { failure = error.localizedDescription }
    }

    static let numbers: [String: WritableKeyPath<VideoCaptionStyle, Double>] = [
        "canvasWidth": \.canvasWidth, "canvasHeight": \.canvasHeight, "fontSize": \.fontSize,
        "lineAdvance": \.lineAdvance, "x": \.x, "y": \.y, "width": \.width,
    ]
}

extension VideoEditorModel {
    func captionDraft(_ caption: VideoProject.Annotation) -> VideoCaptionDraft {
        captionDrafts[caption.id] ?? VideoCaptionDraft(caption, model: self)
    }

    func reconcileCaptionDrafts() {
        let ids = Set(project?.annotations.map(\.id) ?? [])
        for id in captionDrafts.keys where !ids.contains(id) {
            captionDrafts.removeValue(forKey: id)
            for group in ["text", "time", "style"] {
                setPendingViewEdit("caption.\(id).\(group)", hasChanges: false)
            }
        }
        for caption in project?.annotations ?? []
        where caption.type == "text" && captionDrafts[caption.id] == nil {
            captionDrafts[caption.id] = VideoCaptionDraft(caption, model: self)
        }
    }
}
