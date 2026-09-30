import AppKit
import CoreImage
import CoreText
import SwiftUI
import UniformTypeIdentifiers

struct VideoSubtitle: Equatable {
    let start: Double
    let end: Double
    let text: String

    static func parse(_ text: String) -> [VideoSubtitle] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
            of: "\r", with: "\n"
        ).components(separatedBy: "\n")
        var result: [VideoSubtitle] = []
        var index = 0
        while index < lines.count {
            let times = lines[index].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]),
                end > start
            else { index += 1; continue }
            index += 1
            var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[index]); index += 1
            }
            let caption = body.joined(separator: "\n").replacingOccurrences(
                of: "<[^>]+>", with: "", options: .regularExpression)
            if !caption.isEmpty {
                result.append(VideoSubtitle(start: start, end: end, text: caption))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    static func encode(_ cues: [VideoSubtitle], vtt: Bool) -> String {
        let body = cues.enumerated().map { index, cue in
            "\(vtt ? "" : "\(index + 1)\n")\(timestamp(cue.start, vtt: vtt)) --> \(timestamp(cue.end, vtt: vtt))\n\(cue.text)\n"
        }.joined(separator: "\n")
        return (vtt ? "WEBVTT\n\n" : "") + body
    }

    private static func seconds(_ value: String) -> Double? {
        guard let token = value.split(whereSeparator: \.isWhitespace).first else { return nil }
        let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap
        { Double($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.isFinite && $0 >= 0 }),
            parts.last! < 60, parts[parts.count - 2] < 60
        else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func timestamp(_ time: Double, vtt: Bool) -> String {
        let milliseconds = Int((max(0, time) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d%@%03d", milliseconds / 3_600_000,
            milliseconds / 60_000 % 60, milliseconds / 1000 % 60, vtt ? "." : ",",
            milliseconds % 1000)
    }
}

extension VideoProject {
    mutating func splitCaption(_ id: String, at requestedTime: Double) {
        var entries = annotations.map(\.raw)
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let caption = annotations[index]
        let time: Double
        if let anchor = caption.outputCaption {
            guard let position = try? anchor.start.moved(to: requestedTime / 1000) else { return }
            time = position.seconds * 1000
        } else {
            time = requestedTime
        }
        guard time > caption.startMs + 100, time < caption.endMs - 100 else { return }
        let words = caption.text.split(whereSeparator: \.isWhitespace)
        guard words.count > 1 else { return }
        let fraction = (time - caption.startMs) / (caption.endMs - caption.startMs)
        let boundary = min(words.count - 1, max(1, Int((fraction * Double(words.count)).rounded())))
        var right = caption.raw
        let rightID = "annotation_\(UUID().uuidString.lowercased())"
        right["id"] = rightID
        entries[index]["content"] = words.prefix(boundary).joined(separator: " ")
        right["content"] = words.dropFirst(boundary).joined(separator: " ")
        entries[index]["captionWords"] = nil
        right["captionWords"] = nil
        if let anchor = caption.outputCaption {
            do {
                let cut = try anchor.start.moved(to: time / 1000)
                try VideoCaptionAnchor(start: anchor.start, end: cut).store(in: &entries[index])
                try VideoCaptionAnchor(start: cut, end: anchor.end).store(in: &right)
            } catch { return }
            entries.insert(right, at: index + 1)
            root["annotations"] = entries
            return
        }
        entries.insert(right, at: index + 1)
        root["annotations"] = entries
        retimeRegion(
            "annotations", id: id, start: caption.startMs / 1000, end: time / 1000, trimStart: false
        )
        retimeRegion(
            "annotations", id: rightID, start: time / 1000, end: caption.endMs / 1000,
            trimStart: false)
    }

    mutating func mergeCaption(_ id: String) {
        guard let selected = annotations.first(where: { $0.id == id }) else { return }
        let captions = annotations.filter {
            $0.type == "text" && ($0.outputCaption != nil) == (selected.outputCaption != nil)
        }.sorted { $0.startMs < $1.startMs }
        guard let index = captions.firstIndex(where: { $0.id == id }), index + 1 < captions.count
        else { return }
        let left = captions[index]
        let right = captions[index + 1]
        if let leftAnchor = left.outputCaption, let rightAnchor = right.outputCaption {
            var raw = left.raw
            let end =
                leftAnchor.end.seconds >= rightAnchor.end.seconds ? leftAnchor.end : rightAnchor.end
            guard let merged = try? VideoCaptionAnchor(start: leftAnchor.start, end: end),
                (try? merged.store(in: &raw)) != nil
            else { return }
            raw["content"] = left.text + " " + right.text
            raw["captionWords"] = nil
            editRegion("annotations", id: id) { $0 = raw }
            root["annotations"] = annotations.filter { $0.id != right.id }.map(\.raw)
            return
        }
        editRegion("annotations", id: id) {
            $0["content"] = left.text + " " + right.text; $0["captionWords"] = nil
        }
        root["annotations"] = annotations.filter { $0.id != right.id }.map(\.raw)
        retimeRegion(
            "annotations", id: id, start: left.startMs / 1000,
            end: max(left.endMs, right.endMs) / 1000, trimStart: false)
    }
}

extension VideoEditorModel {
    func importCaptions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt") ?? .plainText,
            UTType(filenameExtension: "vtt") ?? .plainText,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let cues = VideoSubtitle.parse(try String(contentsOf: url, encoding: .utf8))
            guard !cues.isEmpty else {
                throw VideoRenderPipeline.RenderError.exportFailed(
                    "No valid subtitle cues were found.")
            }
            mutate { document in
                for cue in cues where cue.start < duration {
                    document.addText(
                        cue.text, startMs: rulerTime(at: cue.start) * 1000,
                        endMs: rulerTime(at: min(duration, cue.end)) * 1000)
                }
            }
            rebuild()
        } catch { errorMessage = error.localizedDescription }
    }

    func exportCaptions(vtt: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: vtt ? "vtt" : "srt") ?? .plainText]
        panel.nameFieldStringValue = "\(project?.title ?? "Captions").\(vtt ? "vtt" : "srt")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cues = (project?.annotations ?? []).filter { $0.type == "text" }.compactMap {
            caption -> VideoSubtitle? in
            let start = captionOutputRange(caption).start
            let end = captionOutputRange(caption).end
            return end > start ? VideoSubtitle(start: start, end: end, text: caption.text) : nil
        }.sorted { $0.start < $1.start }
        do {
            try VideoSubtitle.encode(cues, vtt: vtt).write(
                to: url, atomically: true, encoding: .utf8)
        } catch { errorMessage = error.localizedDescription }
    }
}

struct VideoCaptionEditor: View {
    let model: VideoEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Captions").font(.headline)
            Button(
                model.isTranscribing ? "Transcribing…" : "Generate from speech",
                action: model.generateCaptions
            )
            .disabled(model.isTranscribing || model.selectedClipID == nil)
            HStack {
                Button("Import…", action: model.importCaptions)
                Menu("Export") {
                    Button("SubRip (.srt)") { model.exportCaptions(vtt: false) }
                    Button("WebVTT (.vtt)") { model.exportCaptions(vtt: true) }
                }
            }
            Text(
                "Select a caption to position it on the canvas. Drag its timeline edges to adjust timing."
            )
            .font(.caption).foregroundStyle(.secondary)
            ForEach(
                (model.project?.annotations ?? []).filter { $0.type == "text" }.sorted {
                    model.captionOutputRange($0).start < model.captionOutputRange($1).start
                }
            ) { caption in
                VideoCaptionRow(caption: caption, model: model)
                Divider()
            }
        }
    }
}

private struct VideoCaptionRow: View {
    let caption: VideoProject.Annotation
    let model: VideoEditorModel
    @State private var text = ""
    @State private var start = 0.0
    @State private var end = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Select at \(start.formatted(.number.precision(.fractionLength(2))))s") {
                model.select(.annotation(caption.id))
            }
            TextField("Caption text", text: $text, axis: .vertical)
                .lineLimit(1...5).onSubmit { model.updateCaption(caption.id, text: text) }
            HStack {
                TextField("Start", value: $start, format: .number.precision(.fractionLength(2)))
                    .accessibilityLabel("Caption start")
                Text("to")
                TextField("End", value: $end, format: .number.precision(.fractionLength(2)))
                    .accessibilityLabel("Caption end")
            }.onSubmit {
                model.retime(
                    "annotations", id: caption.id,
                    range: .init(start: max(0, start), end: min(model.duration, end)), edge: "move")
            }
            if caption.captionStyle == nil {
                Toggle(
                    "Highlight words",
                    isOn: Binding(
                        get: {
                            (caption.raw["style"] as? [String: Any])?["highlightWords"] as? Bool
                                ?? false
                        },
                        set: { value in
                            model.mutate {
                                $0.editRegion("annotations", id: caption.id) { region in
                                    var style = region["style"] as? [String: Any] ?? [:]
                                    style["highlightWords"] = value; region["style"] = style
                                }
                            }
                            model.rebuild()
                        }))
            }
            HStack {
                Button("Split") {
                    model.mutate {
                        $0.splitCaption(
                            caption.id,
                            at: (caption.outputCaption == nil
                                ? model.rulerPlayhead : model.playhead) * 1000)
                    };
                    model.rebuild()
                }
                Button("Merge next in same clock") {
                    model.mutate { $0.mergeCaption(caption.id) }; model.rebuild()
                }
            }
            DisclosureGroup("Style & position") {
                VideoCaptionStyleEditor(caption: caption, model: model)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: caption.text) { _, _ in text = caption.text }
        .onChange(of: caption.startMs) { _, _ in refresh() }
        .onChange(of: caption.endMs) { _, _ in refresh() }
    }

    private func refresh() {
        text = caption.text
        start = model.captionOutputRange(caption).start
        end = model.captionOutputRange(caption).end
    }
}

enum VideoCaptionImage {
    static func make(_ annotation: VideoProject.Annotation, time: Double, size: CGSize) -> CIImage?
    {
        let style = annotation.raw["style"] as? [String: Any] ?? [:]
        let proportions = annotation.raw["size"] as? [String: Double] ?? [:]
        let width = max(16, Int(size.width * (proportions["width"] ?? 60) / 100))
        let height = max(16, Int(size.height * (proportions["height"] ?? 12) / 100))
        let fontSize = max(
            12, size.width / 1280 * ((style["fontSize"] as? NSNumber)?.doubleValue ?? 32))
        let color = CIColor(hex: style["color"] as? String ?? "#FFFFFF")
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: color.red, green: color.green, blue: color.blue, alpha: 1),
        ]
        let text = NSMutableAttributedString(string: annotation.text, attributes: attributes)
        if style["highlightWords"] as? Bool == true {
            let words = annotation.text.split(whereSeparator: \.isWhitespace)
            let fraction = max(
                0,
                min(
                    0.999,
                    (time - annotation.startMs) / max(1, annotation.endMs - annotation.startMs)))
            let timing = annotation.raw["captionWords"] as? [[String: Any]] ?? []
            let active =
                timing.firstIndex {
                    fraction >= ($0["start"] as? Double ?? 0)
                        && fraction < ($0["end"] as? Double ?? 1)
                } ?? min(words.count - 1, Int(fraction * Double(words.count)))
            if words.indices.contains(active) {
                let prefix = words.prefix(active).joined(separator: " ")
                let offset = prefix.utf16.count + (active > 0 ? 1 : 0)
                let range = NSRange(location: offset, length: words[active].utf16.count)
                if NSMaxRange(range) <= text.length {
                    text.addAttribute(
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                        value: CGColor(red: 1, green: 0.82, blue: 0.2, alpha: 1), range: range)
                }
            }
        }
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let plate = style["backgroundColor"] as? String, plate != "transparent" {
            let color = CIColor(hex: plate)
            context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(
            rect: CGRect(x: 6, y: 2, width: width - 12, height: height - 4), transform: nil)
        CTFrameDraw(
            CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        return context.makeImage().map(CIImage.init(cgImage:))
    }
}
