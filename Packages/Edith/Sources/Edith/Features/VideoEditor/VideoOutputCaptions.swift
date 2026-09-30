import AVFoundation
import Foundation

public struct VideoCaptionFrameRate: Codable, Equatable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int, denominator: Int = 1) throws {
        let rate = try VideoMarkerFrameRate(numerator: numerator, denominator: denominator)
        self.numerator = rate.numerator
        self.denominator = rate.denominator
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            numerator: values.decode(Int.self, forKey: .numerator),
            denominator: values.decode(Int.self, forKey: .denominator))
    }
}

public struct VideoCaptionPosition: Codable, Equatable, Sendable {
    public let frame: Int64
    public let frameRate: VideoCaptionFrameRate
    public let markerID: String?

    public init(frame: Int64, frameRate: VideoCaptionFrameRate, markerID: String? = nil) throws {
        guard frame >= 0, frame <= VideoMarker.maximumFrame,
            !frame.multipliedReportingOverflow(by: Int64(frameRate.denominator)).overflow,
            markerID.map({ !$0.isEmpty && $0.utf8.count <= 200 }) ?? true
        else {
            throw VideoEditorService.Failure(
                "invalid_caption", "Invalid caption frame or marker ID.")
        }
        self.frame = frame
        self.frameRate = frameRate
        self.markerID = markerID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            frame: values.decode(Int64.self, forKey: .frame),
            frameRate: values.decode(VideoCaptionFrameRate.self, forKey: .frameRate),
            markerID: values.decodeIfPresent(String.self, forKey: .markerID))
    }

    var time: CMTime {
        CMTime(value: frame * Int64(frameRate.denominator), timescale: Int32(frameRate.numerator))
    }

    public var seconds: Double { time.seconds }

    func moved(to seconds: Double) throws -> Self {
        let rate = try VideoMarkerFrameRate(
            numerator: frameRate.numerator, denominator: frameRate.denominator)
        return try Self(frame: rate.frame(at: seconds), frameRate: frameRate)
    }
}

public struct VideoCaptionAnchor: Codable, Equatable, Sendable {
    public let start: VideoCaptionPosition
    public let end: VideoCaptionPosition

    public init(start: VideoCaptionPosition, end: VideoCaptionPosition) throws {
        guard CMTimeCompare(start.time, end.time) < 0 else {
            throw VideoEditorService.Failure(
                "invalid_caption", "Caption end must follow its start.")
        }
        self.start = start
        self.end = end
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            start: values.decode(VideoCaptionPosition.self, forKey: .start),
            end: values.decode(VideoCaptionPosition.self, forKey: .end))
    }

    func contains(_ time: CMTime) -> Bool {
        CMTimeCompare(time, start.time) >= 0 && CMTimeCompare(time, end.time) < 0
    }

    static func decode(_ value: Any) throws -> Self {
        guard let root = value as? [String: Any], Set(root.keys) == ["start", "end"] else {
            throw VideoEditorService.Failure("invalid_caption", "Invalid output caption anchor.")
        }
        for key in ["start", "end"] {
            guard let position = root[key] as? [String: Any],
                Set(position.keys).isSubset(of: ["frame", "frameRate", "markerID"]),
                let rate = position["frameRate"] as? [String: Any],
                Set(rate.keys) == ["numerator", "denominator"]
            else {
                throw VideoEditorService.Failure(
                    "invalid_caption", "Unknown caption anchor fields.")
            }
        }
        return try JSONDecoder().decode(
            Self.self, from: JSONSerialization.data(withJSONObject: root))
    }

    func store(in raw: inout [String: Any]) throws {
        raw["edithOutputCaption"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(self))
        raw["startMs"] = start.seconds * 1000
        raw["endMs"] = end.seconds * 1000
        for key in ["clipId", "sourceStartSec", "sourceEndSec"] { raw.removeValue(forKey: key) }
    }
}

extension VideoProject.Annotation {
    var outputCaption: VideoCaptionAnchor? {
        raw["edithOutputCaption"].flatMap { try? VideoCaptionAnchor.decode($0) }
    }

    func visible(at output: CMTime, rulerMilliseconds: Double) -> Bool {
        if let anchor = outputCaption { return anchor.contains(output) }
        return rulerMilliseconds >= startMs && rulerMilliseconds <= endMs
    }
}

extension VideoProject {
    func validateOutputCaptions() throws {
        var ids = Set<String>()
        for annotation in annotations {
            if let raw = annotation.raw["edithCaptionStyle"] {
                let style = try VideoCaptionStyle.decode(
                    JSONSerialization.data(withJSONObject: raw))
                _ = try VideoStyledCaptionImage.layout(annotation.text, style: style)
            }
            guard ids.insert(annotation.id).inserted else {
                throw VideoEditorService.Failure(
                    "invalid_caption", "Annotation IDs must be unique.")
            }
            if let raw = annotation.raw["edithOutputCaption"] {
                guard annotation.type == "text", annotation.raw["clipId"] == nil else {
                    throw VideoEditorService.Failure(
                        "invalid_caption", "Output captions cannot be clip anchored.")
                }
                _ = try VideoCaptionAnchor.decode(raw)
            }
        }
    }

    @discardableResult
    mutating func addOutputCaption(
        _ content: String, anchor: VideoCaptionAnchor, style: VideoCaptionStyle? = nil
    ) throws -> String {
        if let style { _ = try VideoStyledCaptionImage.layout(content, style: style) }
        addText(content, startMs: anchor.start.seconds * 1000, endMs: anchor.end.seconds * 1000)
        var entries = annotations.map(\.raw)
        try anchor.store(in: &entries[entries.count - 1])
        try style?.store(in: &entries[entries.count - 1])
        root["annotations"] = entries
        return entries.last!["id"] as! String
    }

    mutating func retimeOutputCaption(_ id: String, start: Double, end: Double) throws {
        guard let annotation = annotations.first(where: { $0.id == id }),
            let anchor = annotation.outputCaption
        else { return }
        let changed = try VideoCaptionAnchor(
            start: anchor.start.moved(to: start), end: anchor.end.moved(to: end))
        var raw = annotation.raw
        try changed.store(in: &raw)
        editRegion("annotations", id: id) { $0 = raw }
    }
}

extension VideoEditorModel {
    func captionOutputRange(_ caption: VideoProject.Annotation) -> ZoomTimelineTiming.Range {
        if let anchor = caption.outputCaption {
            return .init(start: anchor.start.seconds, end: anchor.end.seconds)
        }
        return .init(
            start: outputTime(forRulerTime: caption.startMs / 1000),
            end: outputTime(forRulerTime: caption.endMs / 1000))
    }
}
