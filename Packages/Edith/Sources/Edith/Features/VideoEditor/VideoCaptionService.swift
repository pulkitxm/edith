import AVFoundation
import Foundation

extension VideoEditorService {
    public enum CaptionBoundary: Sendable {
        case frame(Int64)
        case marker(String)
    }

    public enum CaptionRate: Sendable {
        case explicit(VideoCaptionFrameRate)
        case project
    }

    public enum CaptionChange: Sendable {
        case add(content: String, start: CaptionBoundary, end: CaptionBoundary, rate: CaptionRate)
        case update(
            id: String, content: String?, start: CaptionBoundary?, end: CaptionBoundary?,
            rate: CaptionRate?)
        case remove(id: String)
    }

    public struct Caption: Codable, Sendable {
        public let id: String
        public let content: String
        public let clock: String
        public let anchor: VideoCaptionAnchor?
        public let startSeconds: Double
        public let endSeconds: Double
    }

    public struct CaptionReport: Codable, Sendable {
        public let version: Int
        public let path: String
        public let written: Bool
        public let captionID: String?
        public let captions: [Caption]
    }

    public static func listCaptions(_ url: URL) throws -> CaptionReport {
        try captionReport(open(url), url: url, written: false, id: nil)
    }

    public static func changeCaption(
        _ change: CaptionChange, in url: URL, dryRun: Bool = false
    ) async throws -> CaptionReport {
        let lock = dryRun ? nil : try await VideoProjectFileAccess.transaction(url)
        defer { withExtendedLifetime(lock) {} }
        let snapshot = try readProject(url)
        var project = snapshot.project
        let id: String
        switch change {
        case let .add(content, start, end, rate):
            try requireCaptionText(content)
            try require(
                project.annotations.count < 10000, "At most 10000 annotations are supported.")
            let anchor = try await captionAnchor(
                start: start, end: end, rate: rate, project: project)
            id = try project.addOutputCaption(content, anchor: anchor)
        case let .update(reference, content, start, end, rate):
            let caption = try requireCaption(reference, project: project)
            try require(
                content != nil || start != nil || end != nil,
                "Specify caption text or a timing boundary.")
            try require(rate == nil || start != nil || end != nil, "FPS requires a timing update.")
            var raw = caption.raw
            if let content {
                try requireCaptionText(content)
                raw["content"] = content
                raw["textContent"] = content
                raw["captionWords"] = nil
            }
            if start != nil || end != nil {
                let anchor = try await captionAnchor(
                    start: start, end: end, rate: rate, project: project,
                    previous: caption.outputCaption)
                try anchor.store(in: &raw)
            }
            project.editRegion("annotations", id: reference) { $0 = raw }
            id = reference
        case .remove(let reference):
            _ = try requireCaption(reference, project: project)
            project.root["annotations"] = project.annotations.filter { $0.id != reference }.map(
                \.raw)
            id = reference
        }
        try validateStructure(project)
        let data = try encodedProject(project)
        try await validateMedia(project)
        let report = try captionReport(project, url: url, written: !dryRun, id: id)
        try Task.checkCancellation()
        if !dryRun {
            try saveEncoded(data, to: url, overwrite: true, expectedSource: snapshot.revision)
        }
        return report
    }

    private static func requireCaptionText(_ text: String) throws {
        try require(
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && text.utf8.count <= 10000,
            "Caption text must contain 1 to 10000 UTF-8 bytes.")
    }

    private static func requireCaption(_ id: String, project: VideoProject) throws
        -> VideoProject.Annotation
    {
        try require(!id.isEmpty && id.utf8.count <= 200, "Invalid caption ID.")
        guard let caption = project.annotations.first(where: { $0.id == id && $0.type == "text" })
        else {
            throw Failure("not_found", "Unknown caption: \(id)")
        }
        return caption
    }

    private static func captionAnchor(
        start: CaptionBoundary?, end: CaptionBoundary?, rate: CaptionRate?, project: VideoProject,
        previous: VideoCaptionAnchor? = nil
    ) async throws -> VideoCaptionAnchor {
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let fps: VideoCaptionFrameRate?
        switch rate {
        case .explicit(let value): fps = value
        case .project:
            if let raw = project.root["edithVideoSettings"] as? [String: Any] {
                guard let numerator = raw["frameRateNumerator"] as? Int,
                    let denominator = raw["frameRateDenominator"] as? Int
                else {
                    throw Failure("invalid_caption", "Project FPS must be rational.")
                }
                fps = try VideoCaptionFrameRate(numerator: numerator, denominator: denominator)
            } else {
                let duration = pipeline.videoComposition.frameDuration
                fps = try VideoCaptionFrameRate(
                    numerator: Int(duration.timescale), denominator: Int(duration.value))
            }
        case nil: fps = nil
        }
        func position(_ boundary: CaptionBoundary?, previous: VideoCaptionPosition?) throws
            -> VideoCaptionPosition
        {
            switch boundary {
            case .frame(let frame):
                guard let fps else {
                    throw Failure("invalid_caption", "Frame boundaries require an FPS choice.")
                }
                return try VideoCaptionPosition(frame: frame, frameRate: fps)
            case .marker(let id):
                let data = try JSONSerialization.data(
                    withJSONObject: project.root["edithMarkers"] ?? [])
                let markers = try JSONDecoder().decode([VideoMarker].self, from: data)
                try VideoMarkers.validate(markers)
                guard let marker = markers.first(where: { $0.id == id }) else {
                    throw Failure("not_found", "Unknown marker: \(id)")
                }
                return try VideoCaptionPosition(
                    frame: marker.frame,
                    frameRate: VideoCaptionFrameRate(
                        numerator: marker.frameRate.numerator,
                        denominator: marker.frameRate.denominator),
                    markerID: marker.id)
            case nil:
                guard let previous else {
                    throw Failure(
                        "invalid_caption", "Both boundaries are required for source-clock captions."
                    )
                }
                return previous
            }
        }
        let anchor = try VideoCaptionAnchor(
            start: position(start, previous: previous?.start),
            end: position(end, previous: previous?.end))
        try require(
            CMTimeCompare(anchor.end.time, pipeline.composition.duration) <= 0,
            "Caption range must be within the output composition.")
        return anchor
    }

    private static func captionReport(_ project: VideoProject, url: URL, written: Bool, id: String?)
        throws -> CaptionReport
    {
        try project.validateOutputCaptions()
        let report = CaptionReport(
            version: 1, path: url.path, written: written, captionID: id,
            captions: project.annotations.filter { $0.type == "text" }.map {
                Caption(
                    id: $0.id, content: $0.text,
                    clock: $0.outputCaption == nil ? "source_ruler" : "output",
                    anchor: $0.outputCaption, startSeconds: $0.startMs / 1000,
                    endSeconds: $0.endMs / 1000)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try require(
            try encoder.encode(report).count < 4 * 1024 * 1024, "Caption report exceeds 4 MiB.")
        return report
    }
}
